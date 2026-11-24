import Foundation
import SwiftUI
import SwiftData
import Security

/// Lets AI agents on this Mac (Claude, Grok-based bots, anything that speaks MCP) read and update
/// the library, using the Model Context Protocol over Streamable HTTP at http://127.0.0.1:<port>/mcp.
///
/// Safety: it listens on the loopback address only, every request needs the secret key from Settings,
/// requests from web pages are refused, and it's off until you turn it on.
/// Changes go through the same model context as the window, so they appear at once and can be undone.
@MainActor
@Observable
final class MCPServer {
    static let shared = MCPServer()

    enum Status: Equatable {
        case off, starting, running, failed(String)
    }

    private(set) var status: Status = .off
    private(set) var token: String = ""
    /// The most recent agent to connect (from its MCP "clientInfo"), and when.
    private(set) var lastClient: String?
    private(set) var lastActivity: Date?

    /// Off until you turn it on in Settings ▸ AI Agents.
    var enabled: Bool = UserDefaults.standard.bool(forKey: "mcpEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "mcpEnabled")
            enabled ? start() : stop()
        }
    }

    var port: UInt16 {
        let p = UserDefaults.standard.integer(forKey: "mcpPort")
        return p > 1024 && p < 65536 ? UInt16(p) : 8765
    }

    var url: String { "http://127.0.0.1:\(port)/mcp" }

    private var http: LocalHTTPServer?
    fileprivate var model: AppModel?
    fileprivate var context: ModelContext?
    private static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private init() {
        token = Keychain.get("mcp") ?? ""
    }

    /// Called once the library's model context exists (the main window's), so tools edit the same data.
    func attach(model: AppModel, context: ModelContext) {
        self.model = model
        self.context = context
        if enabled && status == .off { start() }
    }

    func start() {
        guard http == nil else { return }
        if token.isEmpty { regenerateToken() }
        status = .starting
        let server = LocalHTTPServer { request in await MCPServer.shared.handle(request) }
        http = server
        server.start(port: port) { error in
            Task { @MainActor in
                let s = MCPServer.shared
                if let error {
                    s.status = .failed(error)
                    s.http?.stop()
                    s.http = nil
                } else {
                    s.status = .running
                    s.writeConnectionFile()
                }
            }
        }
    }

    func stop() {
        http?.stop()
        http = nil
        status = .off
        try? FileManager.default.removeItem(at: Self.connectionFile)
    }

    /// A new secret key; agents using the old one stop working until they're given this one.
    func regenerateToken() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = "bl_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        Keychain.set(token, for: "mcp")
        if status == .running { writeConnectionFile() }
    }

    // MARK: Connection file (for the stdio bridge)

    /// ~/Library/Application Support/Binge Library/mcp.json, readable only by you.
    static var connectionFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Binge Library", isDirectory: true).appendingPathComponent("mcp.json")
    }

    private func writeConnectionFile() {
        let file = Self.connectionFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = ["url": url, "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) else { return }
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Settings for agents that connect over HTTP (Claude, Cursor, most MCP clients).
    var httpSetup: String {
        """
        {
          "mcpServers": {
            "binge-library": {
              "type": "http",
              "url": "\(url)",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    /// Settings for agents that start MCP servers as programs (stdio). The bridge reads the key itself.
    var commandSetup: String {
        """
        {
          "mcpServers": {
            "binge-library": {
              "command": "\(Self.bridgePath)"
            }
          }
        }
        """
    }

    /// Path of the bridge inside the app, for agents that start MCP servers as programs.
    static var bridgePath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/binge-mcp").path
    }

    // MARK: HTTP

    func handle(_ request: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        guard request.path == "/mcp" else { return .text("Not found. The MCP endpoint is /mcp.", status: 404) }

        // Web pages can send requests to localhost; MCP clients don't send an Origin, browsers do.
        if let origin = request.headers["origin"], !origin.hasPrefix("http://127.0.0.1"), !origin.hasPrefix("http://localhost") {
            return .text("Requests from web pages aren’t allowed.", status: 403)
        }
        let auth = request.headers["authorization"] ?? ""
        guard !token.isEmpty, Self.constantTimeEqual(auth, "Bearer \(token)") else {
            return LocalHTTPServer.Response(status: 401, headers: ["WWW-Authenticate": "Bearer"],
                body: Data("Missing or wrong key. Copy it from Binge Library ▸ Settings ▸ AI Agents.".utf8))
        }

        switch request.method {
        case "POST": break
        case "DELETE": return LocalHTTPServer.Response(status: 200)   // session ended; nothing to clean up
        default: return LocalHTTPServer.Response(status: 405, headers: ["Allow": "POST, DELETE"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: request.body) else {
            return .json(Self.error(id: NSNull(), code: -32700, message: "Parse error"), status: 400)
        }
        lastActivity = Date()
        let session = request.headers["mcp-session-id"] ?? UUID().uuidString

        if let batch = json as? [[String: Any]] {
            var replies: [[String: Any]] = []
            for message in batch { if let r = await process(message) { replies.append(r) } }
            return replies.isEmpty ? LocalHTTPServer.Response(status: 202) : .json(replies, headers: ["Mcp-Session-Id": session])
        }
        guard let message = json as? [String: Any] else {
            return .json(Self.error(id: NSNull(), code: -32600, message: "Invalid request"), status: 400)
        }
        guard let reply = await process(message) else { return LocalHTTPServer.Response(status: 202) }
        return .json(reply, headers: ["Mcp-Session-Id": session])
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: JSON-RPC

    /// Returns nil for notifications (messages without an id).
    private func process(_ message: [String: Any]) async -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String {
                lastClient = name
            }
            return Self.result(id: id, [
                "protocolVersion": Self.supportedVersions.contains(requested) ? requested : "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "binge-library", "title": "Binge Library", "version": "1.0"],
                "instructions": MCPTools.instructions,
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": MCPTools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard let model, let context else {
                return Self.result(id: id, MCPTools.errorResult("Binge Library is still starting. Try again in a moment."))
            }
            let tools = MCPTools(model: model, context: context)
            do {
                let output = try await tools.call(name, args)
                return Self.result(id: id, MCPTools.successResult(output))
            } catch let e as MCPTools.Failure {
                if case .unknownTool = e { return Self.error(id: id, code: -32602, message: e.message) }
                return Self.result(id: id, MCPTools.errorResult(e.message))
            } catch {
                return Self.result(id: id, MCPTools.errorResult(error.localizedDescription))
            }
        case "resources/list":
            return Self.result(id: id, ["resources": []])
        case "prompts/list":
            return Self.result(id: id, ["prompts": []])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}
