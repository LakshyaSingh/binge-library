import Foundation

struct RecognitionResult {
    enum Method { case gemini, textRecognition, both }

    /// One title read from the screenshot, with its best database matches.
    struct Found {
        var query: String
        var featured: Bool
        /// Confident matches are pre-selected for adding; the rest are offered unticked.
        var confident: Bool
        var candidates: [TMDBResult]
    }

    var method: Method = .textRecognition
    var platform: Platform?
    var detectedTitle: String?
    var titles: [Found] = []
    var notes: [String] = []
}

enum RecognizerError: LocalizedError {
    case unreadableImage
    var errorDescription: String? { "This file couldn’t be opened as an image." }
}

/// Screenshot → titles. Gemini first (reads every title, including Netflix rows and lists),
/// Apple text recognition as fallback, then TMDB matching for each title.
struct Recognizer {
    let tmdb: TMDBClient
    let geminiKey: String?

    func recognize(_ data: Data) async throws -> RecognitionResult {
        guard let image = ImageUtils.cgImage(from: data, maxPixels: 2400) else { throw RecognizerError.unreadableImage }
        var out = RecognitionResult()

        if let key = geminiKey, !key.isEmpty, let jpeg = ImageUtils.jpeg(image) {
            do {
                let g = try await GeminiClient(key: key).recognize(jpeg: jpeg)
                out.method = .gemini
                out.platform = Platform.normalize(g.platform)
                let items = (g.titles ?? []).filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
                out.detectedTitle = items.first?.title
                out.titles = try await matchAll(items)
                if !out.titles.isEmpty { return out }
                out.notes.append(items.isEmpty ? "Gemini found no titles, so text recognition was tried too."
                                               : "Gemini’s titles had no database matches, so text recognition was tried too.")
            } catch let e as TMDBError {
                throw e
            } catch let e as GeminiError {
                out.notes.append(e.status == 429 ? "Gemini’s free quota was reached, so this was read on your Mac."
                                                 : "Gemini didn’t answer, so this was read on your Mac.")
            }
        }

        let lines = try await Task.detached(priority: .userInitiated) { try TextRecognizer.lines(in: image) }.value
        let analysis = TextRecognizer.analyze(lines)
        out.method = out.method == .gemini ? .both : .textRecognition
        out.platform = out.platform ?? analysis.platform
        out.detectedTitle = out.detectedTitle ?? analysis.candidates.first
        out.titles = try await matchText(analysis.candidates)
        return out
    }

    // MARK: Matching

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let a = normalize(a), b = normalize(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let ta = Set(a.split(separator: " ")), tb = Set(b.split(separator: " "))
        let jaccard = Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
        // Containment counts, scaled by how much of the longer title the shorter one covers.
        let contains = (a.contains(b) || b.contains(a))
            ? 0.5 + 0.5 * Double(min(a.count, b.count)) / Double(max(a.count, b.count)) : 0
        return max(jaccard, contains)
    }

    private static func dedupe(_ list: [TMDBResult]) -> [TMDBResult] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    /// Look up every title Gemini read, a few at a time, keeping the original order.
    private func matchAll(_ items: [GeminiGuess.Item]) async throws -> [RecognitionResult.Found] {
        let tmdb = self.tmdb
        var results = [RecognitionResult.Found?](repeating: nil, count: items.count)
        try await withThrowingTaskGroup(of: (Int, RecognitionResult.Found?).self) { group in
            var next = 0
            func launch() {
                guard next < items.count else { return }
                let i = next, item = items[i]
                next += 1
                group.addTask { (i, try await Self.match(item, featured: item.featured ?? (i == 0), tmdb: tmdb)) }
            }
            for _ in 0..<min(6, items.count) { launch() }
            while let (i, found) = try await group.next() {
                results[i] = found
                launch()
            }
        }
        return results.compactMap { $0 }
    }

    private static func match(_ g: GeminiGuess.Item, featured: Bool, tmdb: TMDBClient) async throws -> RecognitionResult.Found? {
        var pool: [TMDBResult]
        do {
            pool = try await tmdb.search(g.title, type: g.type, year: g.year)
            if pool.isEmpty { pool = try await tmdb.search(g.title) }
        } catch TMDBError.badKey { throw TMDBError.badKey } catch { return nil }
        let ranked = pool.map { r -> (TMDBResult, Double, Double) in
            let sim = max(similarity(r.title, g.title), similarity(r.originalTitle, g.title))
            let score = sim * 2 + log10(1 + r.popularity) / 4 + (g.year != nil && r.year == g.year ? 0.5 : 0)
            return (r, score, sim)
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.2 >= 0.5 else { return nil }
        return RecognitionResult.Found(query: g.title, featured: featured, confident: best.2 >= 0.8,
                                       candidates: Array(dedupe(ranked.map(\.0)).prefix(5)))
    }

    /// Fallback: every on-screen text line that closely matches a real title.
    private func matchText(_ candidates: [String]) async throws -> [RecognitionResult.Found] {
        var out: [RecognitionResult.Found] = []
        var seen = Set<String>()
        for (rank, text) in candidates.prefix(12).enumerated() {
            let results: [TMDBResult]
            do { results = try await tmdb.search(text) } catch TMDBError.badKey { throw TMDBError.badKey } catch { continue }
            var ranked: [(result: TMDBResult, sim: Double, score: Double)] = []
            for r in results.prefix(6) {
                let sim = max(Self.similarity(r.title, text), Self.similarity(r.originalTitle, text))
                guard sim >= 0.8 else { continue }
                ranked.append((r, sim, sim + log10(1 + r.popularity) / 8))
            }
            ranked.sort { $0.score > $1.score }
            guard let best = ranked.first, seen.insert(best.result.id).inserted else { continue }
            let candidates: [TMDBResult] = Self.dedupe(ranked.map { $0.result })
            out.append(RecognitionResult.Found(query: text, featured: rank == 0,
                                               confident: rank == 0 || best.sim >= 0.95, candidates: candidates))
        }
        return out
    }
}
