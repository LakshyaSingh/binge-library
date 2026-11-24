import Foundation
import SwiftData

/// One-time import of keys and library from the earlier web version of Binge Library.
enum LegacyImport {
    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Claude Code/Binge Library")
    private static let doneKey = "legacyImportDone"

    @MainActor
    static func runIfNeeded(model: AppModel, context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        _ = run(from: defaultFolder, model: model, context: context)
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    /// Returns how many titles were imported.
    @MainActor
    static func run(from folder: URL, model: AppModel, context: ModelContext) -> Int {
        // Keys from .env, only if not already set.
        if let env = try? String(contentsOf: folder.appendingPathComponent(".env"), encoding: .utf8) {
            var values: [String: String] = [:]
            for line in env.split(separator: "\n") where !line.hasPrefix("#") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
            }
            if !model.hasTMDB, let k = values["TMDB_API_KEY"], !k.isEmpty { model.saveKeys(tmdb: k) }
            if !model.hasGemini, let k = values["GEMINI_API_KEY"], !k.isEmpty { model.saveKeys(gemini: k) }
        }

        // Library from data/library.json.
        struct Legacy: Decodable {
            struct Item: Decodable {
                var tmdbId: Int; var type: String; var title: String; var year: Int?
                var posterUrl: String?; var backdropUrl: String?; var overview: String?; var tagline: String?
                var genres: [String]?; var rating: Double?; var runtime: Int?; var seasons: Int?
                var providers: LegacyProviders?; var region: String?; var spottedOn: String?
                var status: String?; var source: String?; var addedAt: String?
            }
            struct LegacyProviders: Decodable {
                struct P: Decodable { var name: String; var logoUrl: String? }
                var stream: [P]?; var rent: [P]?; var buy: [P]?; var link: String?
                var converted: WatchProviders {
                    func m(_ l: [P]?) -> [ProviderInfo] { (l ?? []).map { ProviderInfo(name: TMDBClient.normalizeProvider($0.name), logoURL: $0.logoUrl) } }
                    return WatchProviders(stream: m(stream), rent: m(rent), buy: m(buy), link: link)
                }
            }
            var items: [Item]
        }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("data/library.json")),
              let legacy = try? JSONDecoder().decode(Legacy.self, from: data) else { return 0 }
        let existing = Set(((try? context.fetch(FetchDescriptor<Title>())) ?? []).map { "\($0.mediaType):\($0.tmdbID)" })
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var count = 0
        for i in legacy.items where !existing.contains("\(i.type):\(i.tmdbId)") {
            let t = Title(tmdbID: i.tmdbId, mediaType: i.type, name: i.title)
            t.year = i.year; t.posterURL = i.posterUrl; t.backdropURL = i.backdropUrl
            t.overview = i.overview ?? ""; t.tagline = i.tagline ?? ""; t.genres = i.genres ?? []
            t.rating = i.rating; t.runtime = i.runtime; t.seasons = i.seasons
            t.providers = i.providers?.converted ?? WatchProviders(); t.region = i.region ?? "US"
            t.spottedOn = i.spottedOn; t.statusRaw = i.status ?? "want"; t.source = i.source ?? "search"
            t.addedAt = i.addedAt.flatMap { iso.date(from: $0) } ?? Date()
            context.insert(t)
            count += 1
        }
        try? context.save()
        return count
    }
}
