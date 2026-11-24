import Foundation
import SwiftUI

struct Recommendation: Identifiable, Hashable {
    let result: TMDBResult
    var score: Double
    /// Library titles that led here, strongest first (names, and their "type:id" keys in the same order).
    var because: [String]
    var becauseKeys: [String] = []
    var id: String { result.id }
}

struct RecommendationRow: Identifiable {
    let source: String
    let watched: Bool
    var liked = false
    let items: [Recommendation]
    var id: String { source }
    var heading: String {
        liked ? "Because you liked \(source)" : watched ? "Because you watched \(source)" : "Because you added \(source)"
    }
}

/// Builds "For You" from TMDB's per-title recommendations across the whole library.
///
/// Every title in the library votes for the titles TMDB recommends alongside it. Votes are
/// weighted by your thumbs (liked counts most; disliked titles don't vote at all), how invested
/// you are (watched > watching > up next), how recently you added it, and how high it ranks in
/// that title's list. Titles recommended by many of yours rise to the top.
@MainActor
@Observable
final class Recommender {
    static let shared = Recommender()

    private(set) var picks: [Recommendation] = []
    private(set) var rows: [RecommendationRow] = []
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var lastError: String?
    private(set) var dismissed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "dismissedRecommendations") ?? [])

    private var builtFor: String = ""
    private var cache: [String: CacheEntry] = Recommender.loadCache()
    private static let cacheLifetime: TimeInterval = 3 * 24 * 3600

    struct CacheEntry: Codable {
        var date: Date
        var results: [TMDBResult]
    }

    /// Rebuild if the library changed since last time (or when forced).
    func refresh(library allTitles: [Title], tmdb: TMDBClient, force: Bool = false) async {
        let signature = allTitles.map { "\($0.mediaType):\($0.tmdbID):\($0.statusRaw):\($0.opinionRaw)" }.sorted().joined(separator: ",")
        guard force || signature != builtFor, !isLoading, !allTitles.isEmpty else { return }
        // Thumbs-down titles don't count toward recommendations.
        let library = allTitles.filter { $0.opinion != .disliked }
        isLoading = true
        lastError = nil
        progress = 0
        defer { isLoading = false }

        if force { cache = [:] }
        let sources = library.map { (key: "\($0.mediaType):\($0.tmdbID)", type: $0.mediaType, id: $0.tmdbID) }
        let missing = sources.filter { s in
            guard let hit = cache[s.key] else { return true }
            // Lists cached before genres were recorded are fetched again once.
            if hit.results.contains(where: { $0.genreIDs == nil }) { return true }
            return Date().timeIntervalSince(hit.date) > Self.cacheLifetime
        }

        // Fetch what isn't cached, eight at a time.
        var done = sources.count - missing.count
        let total = max(sources.count, 1)
        progress = Double(done) / Double(total)
        var failures = 0
        await withTaskGroup(of: (String, [TMDBResult]?).self) { group in
            var next = 0
            func launch() {
                guard next < missing.count else { return }
                let s = missing[next]
                next += 1
                group.addTask { (s.key, try? await tmdb.recommendations(type: s.type, id: s.id)) }
            }
            for _ in 0..<min(8, missing.count) { launch() }
            while let (key, results) = await group.next() {
                if let results { cache[key] = CacheEntry(date: Date(), results: results) } else { failures += 1 }
                done += 1
                progress = Double(done) / Double(total)
                launch()
            }
        }
        if failures == missing.count && !missing.isEmpty { lastError = "Couldn’t reach TMDB. Check your connection and try again." }
        saveCache()
        build(from: library, owned: Set(allTitles.map { "\($0.mediaType):\($0.tmdbID)" }))
        builtFor = signature
    }

    // MARK: Where each recommendation streams

    /// Recommendation id → streaming service ("" when it isn't on a known service). Loaded lazily as cards appear.
    private(set) var platforms: [String: String] = [:]
    private var platformCache: [String: PlatformEntry] = Recommender.loadPlatformCache()
    private var platformsLoading: Set<String> = []

    struct PlatformEntry: Codable {
        var date: Date
        var platform: String
    }

    func platform(for r: TMDBResult) -> Platform? {
        (platforms[r.id] ?? platformCache[r.id]?.platform).flatMap { Platform(rawValue: $0) }
    }

    /// Fetch where a recommended title streams, unless it's cached and fresh.
    func loadPlatform(for r: TMDBResult, tmdb: TMDBClient) async {
        let id = r.id
        if let hit = platformCache[id], Date().timeIntervalSince(hit.date) < Self.cacheLifetime {
            if platforms[id] != hit.platform { platforms[id] = hit.platform }
            return
        }
        guard !platformsLoading.contains(id) else { return }
        platformsLoading.insert(id)
        defer { platformsLoading.remove(id) }
        guard let wp = try? await tmdb.watchProviders(type: r.mediaType, id: r.tmdbID) else { return }
        let name = wp.stream.lazy.compactMap { Platform.exact($0.name) }.first?.rawValue ?? ""
        platformCache[id] = PlatformEntry(date: Date(), platform: name)
        withAnimation(.smooth(duration: 0.25)) { platforms[id] = name }
        schedulePlatformSave()
    }

    private var platformSaveTask: Task<Void, Never>?
    private func schedulePlatformSave() {
        platformSaveTask?.cancel()
        platformSaveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(platformCache) else { return }
            try? data.write(to: Self.platformCacheURL, options: .atomic)
        }
    }

    private static var platformCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("recommendation-platforms.json")
    }

    private static func loadPlatformCache() -> [String: PlatformEntry] {
        guard let data = try? Data(contentsOf: platformCacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: PlatformEntry].self, from: data)) ?? [:]
    }

    func dismiss(_ r: Recommendation) {
        dismissed.insert(r.id)
        UserDefaults.standard.set(Array(dismissed), forKey: "dismissedRecommendations")
        withAnimation(.spring(duration: 0.4)) {
            picks.removeAll { $0.id == r.id }
            rows = rows.map { RecommendationRow(source: $0.source, watched: $0.watched, liked: $0.liked, items: $0.items.filter { $0.id != r.id }) }
        }
    }

    // MARK: Scoring

    private func build(from library: [Title], owned: Set<String>) {
        let byRecency = library.sorted { $0.addedAt > $1.addedAt }
        let count = Double(max(byRecency.count - 1, 1))

        var scores: [String: Double] = [:]
        var reasons: [String: [(key: String, name: String, vote: Double)]] = [:]
        var results: [String: TMDBResult] = [:]
        var sourceWeights: [(title: Title, weight: Double)] = []

        for (i, t) in byRecency.enumerated() {
            guard let recs = cache["\(t.mediaType):\(t.tmdbID)"]?.results else { continue }
            let investment: Double = switch (t.opinion, t.status) {
            case (.liked, _): 2.0
            case (_, .watched): 1.4
            case (_, .watching): 1.3
            default: 1.0
            }
            let recency = 1 + 0.5 * (1 - Double(i) / count)      // newest adds count up to 1.5×
            let weight = investment * recency
            sourceWeights.append((t, weight))
            for (rank, r) in recs.enumerated() where !owned.contains(r.id) && !dismissed.contains(r.id) && r.posterURL != nil {
                let vote = weight / (Double(rank) + 1).squareRoot()
                scores[r.id, default: 0] += vote
                reasons[r.id, default: []].append(("\(t.mediaType):\(t.tmdbID)", t.name, vote))
                results[r.id] = r
            }
        }

        func quality(_ r: TMDBResult) -> Double {
            // Gently favour well-rated titles; unrated ones are neutral.
            guard let rating = r.rating else { return 0.85 }
            return 0.6 + 0.4 * min(1, rating / 8)
        }

        let ranked = scores.compactMap { id, score -> Recommendation? in
            guard let r = results[id] else { return nil }
            let sorted = (reasons[id] ?? []).sorted { $0.vote > $1.vote }
            return Recommendation(result: r, score: score * quality(r), because: sorted.map(\.name), becauseKeys: sorted.map(\.key))
        }.sorted { $0.score > $1.score }

        picks = Array(ranked.prefix(36))

        // Rows for the titles you're most invested in, so each has its own shelf.
        let rowSources = sourceWeights.sorted { $0.weight > $1.weight }.prefix(8)
        var newRows: [RecommendationRow] = []
        for (t, _) in rowSources {
            let items = (cache["\(t.mediaType):\(t.tmdbID)"]?.results ?? [])
                .filter { !owned.contains($0.id) && !dismissed.contains($0.id) && $0.posterURL != nil }
                .prefix(15)
                .map { Recommendation(result: $0, score: 0, because: [t.name], becauseKeys: ["\(t.mediaType):\(t.tmdbID)"]) }
            if items.count >= 5 {
                newRows.append(RecommendationRow(source: t.name, watched: t.status == .watched, liked: t.opinion == .liked, items: items))
            }
            if newRows.count == 5 { break }
        }
        withAnimation(.spring(duration: 0.5, bounce: 0.15)) { rows = newRows }
    }

    // MARK: Cache on disk, so relaunching doesn't re-download everything

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("recommendations.json")
    }

    private static func loadCache() -> [String: CacheEntry] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: CacheEntry].self, from: data)) ?? [:]
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.cacheURL, options: .atomic) }
    }
}
