// binge-mcp: connects agents that start MCP servers as programs (stdio) to Binge Library's
// built-in MCP server. It reads JSON-RPC messages line by line from stdin, forwards each one to
// http://127.0.0.1:<port>/mcp with the key from ~/Library/Application Support/Binge Library/mcp.json,
// and writes the replies to stdout. If Binge Library isn't running, it opens it in the background.

import Foundation

let bundleID = "com.lakshyasingh.BingeLibrary"
let connectionFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Binge Library/mcp.json")

struct Connection { var url: URL; var token: String }

func log(_ s: String) { FileHandle.standardError.write(Data("binge-mcp: \(s)\n".utf8)) }

func readConnection() -> Connection? {
    guard let data = try? Data(contentsOf: connectionFile),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let u = obj["url"], let url = URL(string: u), let token = obj["token"] else { return nil }
    return Connection(url: url, token: token)
}

var sessionID: String?
var launchedApp = false

enum PostResult { case reply(Data), accepted, unauthorized, unreachable(String) }

func post(_ body: Data, to c: Connection) -> PostResult {
    var req = URLRequest(url: c.url, timeoutInterval: 120)
    req.httpMethod = "POST"
    req.httpBody = body
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    req.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
    if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
    let done = DispatchSemaphore(value: 0)
    var result = PostResult.unreachable("no response")
    URLSession.shared.dataTask(with: req) { data, response, error in
        defer { done.signal() }
        if let error { result = .unreachable(error.localizedDescription); return }
        guard let http = response as? HTTPURLResponse else { return }
        if let s = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = s }
        switch http.statusCode {
        case 200: result = .reply(data ?? Data())
        case 202: result = .accepted
        case 401: result = .unauthorized
        default: result = .unreachable("HTTP \(http.statusCode): \(String(decoding: data ?? Data(), as: UTF8.self))")
        }
    }.resume()
    done.wait()
    return result
}

/// Opens Binge Library in the background and waits for its server, up to 20 seconds.
func launchAppAndWait() -> Connection? {
    if !launchedApp {
        launchedApp = true
        log("opening Binge Library…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-b", bundleID]
        try? p.run()
        p.waitUntilExit()
    }
    for _ in 0..<40 {
        Thread.sleep(forTimeInterval: 0.5)
        if let c = readConnection(), case .reply = ping(c) { return c }
    }
    return nil
}

func ping(_ c: Connection) -> PostResult {
    post(Data(#"{"jsonrpc":"2.0","id":"binge-mcp-ping","method":"ping"}"#.utf8), to: c)
}

func write(_ data: Data) {
    var out = data
    if out.last != UInt8(ascii: "\n") { out.append(UInt8(ascii: "\n")) }
    FileHandle.standardOutput.write(out)
}

func errorReply(id: Any, _ message: String) -> Data {
    let obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
}

let offMessage = "Binge Library’s agent access is off. In Binge Library, open Settings ▸ AI Agents and turn on “Let AI agents use your library”."

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    let body = Data(trimmed.utf8)
    let parsed = try? JSONSerialization.jsonObject(with: body)
    let id: Any? = (parsed as? [String: Any])?["id"]

    var connection = readConnection()
    if connection == nil { connection = launchAppAndWait() }
    guard var c = connection else {
        if let id { write(errorReply(id: id, offMessage)) }
        continue
    }

    var result = post(body, to: c)
    if case .unauthorized = result, let fresh = readConnection() {   // the key was changed: reread it
        c = fresh
        result = post(body, to: c)
    }
    if case .unreachable = result, let started = launchAppAndWait() {   // app quit since we started
        c = started
        result = post(body, to: c)
    }

    switch result {
    case .reply(let data): write(data)
    case .accepted: break
    case .unauthorized:
        if let id { write(errorReply(id: id, "Binge Library rejected the key. Turn agent access off and on again in Settings ▸ AI Agents.")) }
    case .unreachable(let why):
        log(why)
        if let id { write(errorReply(id: id, readConnection() == nil ? offMessage : "Couldn’t reach Binge Library: \(why)")) }
    }
}
