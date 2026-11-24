import Foundation
import Network

/// A tiny HTTP/1.1 server bound to 127.0.0.1, just enough for MCP's Streamable HTTP transport.
/// Each connection carries one request; the response closes it.
final class LocalHTTPServer: @unchecked Sendable {
    struct Request {
        var method: String
        var path: String
        var headers: [String: String]   // lowercased names
        var body: Data
    }

    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            var h = headers
            h["Content-Type"] = "application/json"
            return Response(status: status, headers: h, body: data)
        }

        static func text(_ text: String, status: Int) -> Response {
            Response(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
        }
    }

    typealias Handler = @Sendable (Request) async -> Response

    private let queue = DispatchQueue(label: "com.lakshyasingh.BingeLibrary.mcp-http")
    private var listener: NWListener?
    private let handler: Handler
    private static let maxRequest = 4 << 20

    init(handler: @escaping Handler) { self.handler = handler }

    /// Starts listening; `ready` reports success or a readable error (for example, port already in use).
    func start(port: UInt16, ready: @escaping @Sendable (String?) -> Void) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Only this Mac can connect: bind to the loopback address, not every network interface.
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: ready(nil)
                case .failed(let e):
                    if case .posix(let code) = e, code == .EADDRINUSE {
                        ready("Port \(port) is already in use by another app.")
                    } else {
                        ready(e.localizedDescription)
                    }
                default: break
                }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            ready(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > Self.maxRequest { return self.send(.text("Request too large", status: 413), on: conn) }
            if let request = Self.parse(buf) {
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.send(response, on: conn)
                }
            } else if done || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    /// Returns a request once the headers and the whole body (by Content-Length) have arrived.
    private static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]
        let path = String(requestLine[1]).components(separatedBy: "?").first ?? "/"
        return Request(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: Data(body))
    }

    private func send(_ response: Response, on conn: NWConnection) {
        let reason: String = switch response.status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        default: "Error"
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
