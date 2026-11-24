import Foundation

struct GeminiGuess: Decodable {
    struct Item: Decodable {
        var title: String
        var type: String?
        var year: Int?
        var featured: Bool?
    }
    var platform: String?
    var titles: [Item]?
}

enum GeminiError: LocalizedError {
    case http(Int, String), timeout, empty
    var status: Int {
        switch self {
        case .http(let c, _): c
        case .timeout: 504
        case .empty: 500
        }
    }
    var errorDescription: String? {
        switch self {
        case .http(429, _): "Gemini’s free quota was reached."
        case .http(let c, let body): "Gemini error \(c): \(body.prefix(120))"
        case .timeout: "Gemini took too long to answer."
        case .empty: "Gemini returned no answer."
        }
    }
}

/// Reads streaming screenshots with Google's Gemini (Interactions API, free tier works).
struct GeminiClient {
    let key: String

    /// Fastest reliable model first. We fall back when a model is busy, retired, rate-limited or hangs.
    static let models = ["gemini-3.6-flash", "gemini-3.8-flash", "gemini-3.5-flash-lite"]

    /// Models that recently hung or reported overload are skipped for a while.
    private static let cooldown = Cooldown()
    final class Cooldown: @unchecked Sendable {
        private var until: [String: Date] = [:]
        private let lock = NSLock()
        func isCooling(_ m: String) -> Bool { lock.lock(); defer { lock.unlock() }; return (until[m] ?? .distantPast) > Date() }
        func cool(_ m: String) { lock.lock(); until[m] = Date().addingTimeInterval(600); lock.unlock() }
    }

    private static let prompt = """
    You are looking at a screenshot taken while browsing a streaming service (Netflix, Prime Video, Apple TV, Hulu, HBO Max, Disney+, Peacock, Paramount+), or a list of movies and shows.
    List EVERY movie or TV show title visible in it:
    - the featured title (hero banner, title page, or selected tile), marked featured: true
    - every title in rows and grids such as "More Like This", "Because you watched", "Top 10", "Continue Watching", "Recommended", and every item in a written list.
    Titles are often drawn as stylized logos on poster art — read them carefully. Give the title as it would appear in a movie database (no "Season 2", no episode names).
    Do NOT include menu items, genre or row names, actor names, or text you can't read confidently.
    Order: featured first, then reading order (left to right, top to bottom). At most 40 titles.
    "type" is "movie" or "tv" when you can tell, otherwise null. "year" only if shown.
    Platform is the service whose interface this is: Netflix, Prime Video, Apple TV, Hulu, HBO Max, Disney+, Peacock, Paramount+, or null.
    If it's not a screenshot of movies or shows, return an empty titles array.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "platform": ["type": "string", "nullable": true],
            "titles": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "type": ["type": "string", "enum": ["movie", "tv"], "nullable": true],
                        "year": ["type": "integer", "nullable": true],
                        "featured": ["type": "boolean"],
                    ],
                    "required": ["title"],
                ],
            ],
        ],
        "required": ["titles"],
    ]

    func recognize(jpeg: Data) async throws -> GeminiGuess {
        var lastError: Error = GeminiError.empty
        let ready = Self.models.filter { !Self.cooldown.isCooling($0) }
        for model in ready.isEmpty ? Self.models : ready {
            do {
                return try await call(model: model, jpeg: jpeg)
            } catch let e as GeminiError {
                lastError = e
                if [400, 401, 403].contains(e.status) { break } // bad key or request: other models won't help
                if [404, 429, 500, 503, 504].contains(e.status) { Self.cooldown.cool(model) }
            } catch {
                lastError = error
                Self.cooldown.cool(model)
            }
        }
        throw lastError
    }

    private func call(model: String, jpeg: Data) async throws -> GeminiGuess {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30   // lists take longer than single titles
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "model": model,
            "input": [
                ["type": "image", "data": jpeg.base64EncodedString(), "mime_type": "image/jpeg"],
                ["type": "text", "text": Self.prompt],
            ],
            "response_format": Self.schema,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch let e as URLError where e.code == .timedOut { throw GeminiError.timeout }
        catch { throw GeminiError.http(0, error.localizedDescription) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw GeminiError.http(code, String(decoding: data, as: UTF8.self)) }

        // Text lives in steps[] where type == "model_output" → content[].text
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let steps = json?["steps"] as? [[String: Any]] ?? []
        let text = steps.filter { $0["type"] as? String == "model_output" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^```(json)?|```$"#, with: "", options: .regularExpression)
        guard let textData = text.data(using: .utf8), !text.isEmpty else { throw GeminiError.empty }
        return try JSONDecoder().decode(GeminiGuess.self, from: textData)
    }
}
