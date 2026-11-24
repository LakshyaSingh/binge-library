import Foundation
import SwiftData

/// The library tools agents can call. Titles are identified by an id like "tv:1396" or "movie:27205"
/// (TMDB media type and id); tools that take a title also accept its exact name.
@MainActor
struct MCPTools {
    let model: AppModel
    let context: ModelContext

    enum Failure: Error {
        case unknownTool(String), invalid(String)
        var message: String {
            switch self {
            case .unknownTool(let n): "Unknown tool: \(n)"
            case .invalid(let m): m
            }
        }
    }

    static let instructions = """
    Binge Library is the user's personal watchlist of movies and TV shows on their Mac.
    Each title has a status (Up Next = want to watch, Watching, Watched), an optional thumbs up/down \
    (thumbs-down titles are ignored for recommendations), the streaming platform it was spotted on, \
    and US streaming availability from TMDB/JustWatch. Titles are identified by ids like "tv:1396" or "movie:27205".
    Use search_library before adding to avoid duplicates (add_title also refuses duplicates). \
    To add something, add_title with a name is usually enough; use search_tmdb first if the name is ambiguous.
    """

    // MARK: Definitions

    private static let statusEnum = ["up_next", "watching", "watched"]
    private static let opinionEnum = ["liked", "disliked", "none"]
    private static let platformNames = Platform.allCases.map(\.rawValue)
    private static let genreNames = Genre.allCases.map(\.rawValue)

    static var definitions: [[String: Any]] {
        func prop(_ type: String, _ description: String, enum values: [String]? = nil) -> [String: Any] {
            var p: [String: Any] = ["type": type, "description": description]
            if let values { p["enum"] = values }
            return p
        }
        func tool(_ name: String, _ title: String, _ description: String, _ props: [String: Any], required: [String] = [],
                  readOnly: Bool, destructive: Bool = false, idempotent: Bool = false, openWorld: Bool = false) -> [String: Any] {
            ["name": name, "title": title, "description": description,
             "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false],
             "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
                             "idempotentHint": idempotent, "openWorldHint": openWorld]]
        }
        let titleArg = prop("string", "Title id like \"tv:1396\" (from other tools), or the title's exact name.")
        return [
            tool("search_library", "Search Library",
                 "List titles in the user's watchlist, optionally filtered. With no arguments, returns the most recently added titles.",
                 ["query": prop("string", "Text to look for in the title name."),
                  "status": prop("string", "Only titles with this status.", enum: statusEnum),
                  "platform": prop("string", "Only titles spotted on or streaming on this service.", enum: platformNames),
                  "genre": prop("string", "Only titles in this genre group, e.g. \"Mystery & Thriller\". Loose matches like \"thriller\" work too."),
                  "type": prop("string", "Only movies or only series.", enum: ["movie", "series"]),
                  "opinion": prop("string", "Only liked, disliked or unrated titles.", enum: opinionEnum),
                  "sort": prop("string", "Order of results (default: recently added).", enum: ["recently_added", "rating", "name", "newest"]),
                  "limit": prop("integer", "Maximum results, 1–200 (default 50).")],
                 readOnly: true, idempotent: true),
            tool("get_title", "Get Title Details",
                 "Full details for one title in the library: summary, genres, runtime or seasons, status, rating, where to watch in the US, links that open it on each service, and its trailer.",
                 ["title": titleArg], required: ["title"], readOnly: true, idempotent: true),
            tool("library_summary", "Library Summary",
                 "Counts across the whole library: by status, streaming service, genre, movie vs series, and thumbs up/down.",
                 [:], readOnly: true, idempotent: true),
            tool("search_tmdb", "Search Movie Database",
                 "Search TMDB (the movie and TV database) for titles that may not be in the library yet. Returns ids to use with add_title, and whether each is already in the library.",
                 ["query": prop("string", "Title to search for."),
                  "type": prop("string", "Only movies or only series.", enum: ["movie", "series"]),
                  "year": prop("integer", "Release or first-air year, to narrow results.")],
                 required: ["query"], readOnly: true, idempotent: true, openWorld: true),
            tool("add_title", "Add Title",
                 "Add a movie or show to the library. Give either a name (the best TMDB match is used) or an id from search_tmdb. Already-added titles are not duplicated.",
                 ["name": prop("string", "Movie or show name, e.g. \"Severance\"."),
                  "id": prop("string", "Exact TMDB id from search_tmdb, like \"tv:95396\". Takes priority over name."),
                  "type": prop("string", "Helps pick the right match when adding by name.", enum: ["movie", "series"]),
                  "year": prop("integer", "Helps pick the right match when adding by name."),
                  "status": prop("string", "Status to give it (default up_next).", enum: statusEnum),
                  "spotted_on": prop("string", "Service where the user saw it.", enum: platformNames)],
                 readOnly: false, openWorld: true),
            tool("update_title", "Update Title",
                 "Change a library title's status, seasons watched, thumbs up/down, or the service it was spotted on. Only the fields you pass change.",
                 ["title": titleArg,
                  "status": prop("string", "New status.", enum: statusEnum),
                  "opinion": prop("string", "Thumbs up (liked), thumbs down (disliked, excluded from recommendations), or none.", enum: opinionEnum),
                  "spotted_on": prop("string", "Service where it was spotted, or \"none\" to clear.", enum: platformNames + ["none"]),
                  "seasons_watched": prop("integer", "Series only: seasons watched so far, counted from Season 1 (0 = none). All seasons marks it Watched; fewer keeps it in Up Next too.")],
                 required: ["title"], readOnly: false, idempotent: true),
            tool("get_updates", "Get Updates",
                 "The app's Updates page: alerts about titles in the library (newly streaming with a subscription, new seasons announced, season premieres), newest first.",
                 ["unread_only": prop("boolean", "Only updates the user hasn't seen."),
                  "limit": prop("integer", "Maximum updates, 1–100 (default 20).")],
                 readOnly: true),
            tool("remove_title", "Remove Title",
                 "Remove a title from the library. The user can undo it in the app with Edit ▸ Undo.",
                 ["title": titleArg], required: ["title"], readOnly: false, destructive: true, idempotent: true),
            tool("get_recommendations", "Get Recommendations",
                 "Personalized picks based on the whole library (the app's For You page), with the library titles behind each pick and where it streams. Thumbs-down titles are ignored; liked titles count most.",
                 ["limit": prop("integer", "Maximum picks, 1–36 (default 12)."),
                  "type": prop("string", "Only movies or only series.", enum: ["movie", "series"]),
                  "genre": prop("string", "Only picks in this genre group, e.g. \"Comedy\".")],
                 readOnly: true, openWorld: true),
        ]
    }

    // MARK: Results

    static func successResult(_ object: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
                "structuredContent": object, "isError": false]
    }

    static func errorResult(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    // MARK: Dispatch

    func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "search_library": return try searchLibrary(args)
        case "get_title": return try await getTitle(args)
        case "library_summary": return try summary()
        case "search_tmdb": return try await searchTMDB(args)
        case "add_title": return try await addTitle(args)
        case "update_title": return try updateTitle(args)
        case "remove_title": return try removeTitle(args)
        case "get_updates": return updates(args)
        case "get_recommendations": return try await recommendations(args)
        default: throw Failure.unknownTool(name)
        }
    }

    // MARK: Reading

    private func allTitles() throws -> [Title] {
        try context.fetch(FetchDescriptor<Title>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))
    }

    private func searchLibrary(_ a: [String: Any]) throws -> [String: Any] {
        var list = try allTitles()
        if let q = string(a, "query"), !q.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        if let s = string(a, "status") { let st = try status(s); list = list.filter { $0.isIn(st) } }
        if let p = string(a, "platform") { let pl = try platform(p); list = list.filter { $0.allPlatforms.contains(pl) } }
        if let g = string(a, "genre") { let gr = try genre(g); list = list.filter { gr.matches(names: $0.genres) } }
        if let t = string(a, "type") { let tv = try isSeries(t); list = list.filter { $0.isTV == tv } }
        if let o = string(a, "opinion") { let op = try opinion(o); list = list.filter { $0.opinion == op } }
        switch string(a, "sort") ?? "recently_added" {
        case "rating": list.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case "name": list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "newest": list.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        default: break
        }
        let limit = min(max(int(a, "limit") ?? 50, 1), 200)
        return ["total_matching": list.count, "returned": min(limit, list.count), "titles": list.prefix(limit).map(Self.brief)]
    }

    private func getTitle(_ a: [String: Any]) async throws -> [String: Any] {
        let t = try find(a)
        // Exact pages on each service (the same links as the app's "Open in" buttons).
        await LinkResolver.shared.load(type: t.mediaType, id: t.tmdbID, name: t.name)
        var d = Self.brief(t)
        d["overview"] = t.overview
        if !t.tagline.isEmpty { d["tagline"] = t.tagline }
        if let r = t.runtime { d["runtime_minutes"] = r }
        if let s = t.seasons { d["seasons"] = s }
        if let p = t.platform { d["spotted_on"] = p.rawValue }
        d["source"] = t.source
        let providers = t.providers
        d["where_to_watch_us"] = ["stream": providers.stream.map(\.name), "rent": providers.rent.map(\.name), "buy": providers.buy.map(\.name)]
        var links: [String: String] = [:]
        for p in t.watchPlatforms {
            if let url = LinkResolver.shared.url(for: p.rawValue, type: t.mediaType, id: t.tmdbID) ?? p.link(for: t.name) {
                links[p.rawValue] = url.absoluteString
            }
        }
        if !links.isEmpty { d["open_links"] = links }
        if let key = t.trailerKey { d["trailer"] = "https://www.youtube.com/watch?v=\(key)" }
        if let poster = t.posterURL { d["poster"] = poster }
        d["tmdb_page"] = "https://www.themoviedb.org/\(t.mediaType)/\(t.tmdbID)"
        return d
    }

    private func summary() throws -> [String: Any] {
        let list = try allTitles()
        var byStatus: [String: Int] = [:], byPlatform: [String: Int] = [:], byGenre: [String: Int] = [:]
        for t in list {
            byStatus[Self.statusName(t.status), default: 0] += 1
            for p in t.allPlatforms { byPlatform[p.rawValue, default: 0] += 1 }
            for g in Genre.groups(names: t.genres) { byGenre[g.rawValue, default: 0] += 1 }
        }
        return ["total": list.count,
                "movies": list.filter { !$0.isTV }.count, "series": list.filter(\.isTV).count,
                "by_status": byStatus, "by_platform": byPlatform, "by_genre": byGenre,
                "liked": list.filter { $0.opinion == .liked }.count, "disliked": list.filter { $0.opinion == .disliked }.count]
    }

    private func searchTMDB(_ a: [String: Any]) async throws -> [String: Any] {
        guard let q = string(a, "query"), !q.isEmpty else { throw Failure.invalid("query is required.") }
        guard model.hasTMDB else { throw Failure.invalid("No TMDB key is set in Binge Library ▸ Settings.") }
        let type = try string(a, "type").map { try isSeries($0) ? "tv" : "movie" }
        let results = try await model.tmdb.search(q, type: type, year: int(a, "year"))
        let owned = model.libraryKeys
        return ["results": results.prefix(10).map { r -> [String: Any] in
            var d: [String: Any] = ["id": r.id, "name": r.title, "type": r.isTV ? "series" : "movie",
                                    "in_library": owned.contains(r.id), "overview": String(r.overview.prefix(240))]
            if let y = r.year { d["year"] = y }
            if let rt = r.rating { d["rating"] = rt }
            return d
        }]
    }

    // MARK: Changing

    private func addTitle(_ a: [String: Any]) async throws -> [String: Any] {
        guard model.hasTMDB else { throw Failure.invalid("No TMDB key is set in Binge Library ▸ Settings.") }
        let wantedStatus = try string(a, "status").map(status) ?? .want
        let spotted = try string(a, "spotted_on").map(platform)
        var alternatives: [TMDBResult] = []
        let pick: TMDBResult

        if let idString = string(a, "id") {
            let (type, id) = try parseID(idString)
            pick = TMDBResult(tmdbID: id, mediaType: type, title: "", originalTitle: "", year: nil, posterURL: nil,
                              overview: "", rating: nil, popularity: 0)
        } else if let name = string(a, "name"), !name.isEmpty {
            let type = try string(a, "type").map { try isSeries($0) ? "tv" : "movie" }
            let year = int(a, "year")
            var pool = try await model.tmdb.search(name, type: type, year: year)
            if pool.isEmpty, type != nil || year != nil { pool = try await model.tmdb.search(name) }
            let ranked = pool.map { r -> (TMDBResult, Double, Double) in
                let sim = max(Recognizer.similarity(r.title, name), Recognizer.similarity(r.originalTitle, name))
                return (r, sim * 2 + log10(1 + r.popularity) / 4 + (year != nil && r.year == year ? 0.5 : 0), sim)
            }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first, best.2 >= 0.5 else {
                throw Failure.invalid("No good match for “\(name)” on TMDB. Try search_tmdb and add by id."
                    + (ranked.isEmpty ? "" : " Closest: " + ranked.prefix(3).map { "\($0.0.title) (\($0.0.year.map(String.init) ?? "?"), \($0.0.id))" }.joined(separator: "; ")))
            }
            pick = best.0
            alternatives = Array(ranked.dropFirst().prefix(4).map(\.0))
        } else {
            throw Failure.invalid("Give a name or an id.")
        }

        let outcome = try await model.add(pick, spottedOn: spotted, source: "agent", context: context)
        let title = outcome.title
        var result: [String: Any] = [:]
        switch outcome {
        case .added:
            title.status = wantedStatus
            result["result"] = "added"
        case .alreadyInLibrary:
            result["result"] = "already_in_library"
        }
        try? context.save()
        result["title"] = Self.brief(title)
        if !alternatives.isEmpty {
            result["other_matches"] = alternatives.map { r in
                ["id": r.id, "name": r.title, "type": r.isTV ? "series" : "movie", "year": r.year.map { $0 as Any } ?? NSNull()]
            }
        }
        return result
    }

    private func updateTitle(_ a: [String: Any]) throws -> [String: Any] {
        let t = try find(a)
        var changed: [String] = []
        if let s = string(a, "status") { t.status = try status(s); changed.append("status") }
        if let o = string(a, "opinion") { t.opinion = try opinion(o); changed.append("opinion") }
        if let p = string(a, "spotted_on") {
            t.platform = p.lowercased() == "none" ? nil : try platform(p)
            changed.append("spotted_on")
        }
        if let n = int(a, "seasons_watched") {
            guard t.isTV else { throw Failure.invalid("\(t.name) is a movie; seasons_watched is for series.") }
            t.markSeasons(n); changed.append("seasons_watched")
        }
        guard !changed.isEmpty else { throw Failure.invalid("Nothing to change: pass status, seasons_watched, opinion or spotted_on.") }
        try? context.save()
        return ["changed": changed, "title": Self.brief(t)]
    }

    private func updates(_ a: [String: Any]) -> [String: Any] {
        var list = UpdatesStore.shared.items
        if (a["unread_only"] as? Bool) == true { list = list.filter { !$0.read } }
        let limit = min(max(int(a, "limit") ?? 20, 1), 100)
        let iso = ISO8601DateFormatter()
        return ["updates": list.prefix(limit).map { u in
            ["title_id": u.titleID, "headline": u.headline, "detail": u.body, "kind": u.kind.rawValue,
             "date": iso.string(from: u.date), "read": u.read] as [String: Any]
        }, "unread": UpdatesStore.shared.unreadCount]
    }

    private func removeTitle(_ a: [String: Any]) throws -> [String: Any] {
        let t = try find(a)
        let info = Self.brief(t)
        context.delete(t)
        try? context.save()
        return ["removed": info, "note": "The user can undo this in Binge Library with Edit ▸ Undo."]
    }

    private func recommendations(_ a: [String: Any]) async throws -> [String: Any] {
        guard model.hasTMDB else { throw Failure.invalid("No TMDB key is set in Binge Library ▸ Settings.") }
        let rec = Recommender.shared
        await rec.refresh(library: try allTitles(), tmdb: model.tmdb)
        var picks = rec.picks.filter { !model.libraryKeys.contains($0.id) }
        if let t = string(a, "type") { let tv = try isSeries(t); picks = picks.filter { $0.result.isTV == tv } }
        if let g = string(a, "genre") { let gr = try genre(g); picks = picks.filter { gr.matches(ids: $0.result.genreIDs ?? []) } }
        let limit = min(max(int(a, "limit") ?? 12, 1), 36)
        var out: [[String: Any]] = []
        for p in picks.prefix(limit) {
            await rec.loadPlatform(for: p.result, tmdb: model.tmdb)
            var d: [String: Any] = ["id": p.id, "name": p.result.title, "type": p.result.isTV ? "series" : "movie",
                                    "overview": String(p.result.overview.prefix(240)),
                                    "because_you_have": Array(p.because.prefix(5)), "sources_count": p.because.count]
            if let y = p.result.year { d["year"] = y }
            if let r = p.result.rating { d["rating"] = r }
            if let pl = rec.platform(for: p.result) { d["streaming_on"] = pl.rawValue }
            out.append(d)
        }
        return ["recommendations": out]
    }

    // MARK: Helpers

    static func brief(_ t: Title) -> [String: Any] {
        var d: [String: Any] = ["id": "\(t.mediaType):\(t.tmdbID)", "name": t.name, "type": t.isTV ? "series" : "movie",
                                "status": statusName(t.status), "opinion": t.opinion.rawValue,
                                "platforms": t.watchPlatforms.map(\.rawValue), "genres": t.genres,
                                "added": ISO8601DateFormatter().string(from: t.addedAt)]
        if let y = t.year { d["year"] = y }
        if let r = t.rating { d["rating"] = r }
        if t.isTV {
            if let s = t.seasons { d["seasons"] = s }
            d["seasons_watched"] = t.seasonsWatched
            if let left = t.seasonsLeft { d["seasons_left"] = left; d["also_in"] = ["up_next", "watched"] }
        }
        return d
    }

    private static func statusName(_ s: WatchStatus) -> String {
        switch s { case .want: "up_next"; case .watching: "watching"; case .watched: "watched" }
    }

    private func string(_ a: [String: Any], _ k: String) -> String? {
        (a[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func int(_ a: [String: Any], _ k: String) -> Int? {
        if let i = a[k] as? Int { return i }
        if let d = a[k] as? Double { return Int(d) }
        if let s = a[k] as? String { return Int(s) }
        return nil
    }

    private func status(_ s: String) throws -> WatchStatus {
        switch s.lowercased().replacingOccurrences(of: " ", with: "_") {
        case "up_next", "upnext", "want", "watchlist", "to_watch": return .want
        case "watching", "in_progress": return .watching
        case "watched", "done", "seen", "finished": return .watched
        default: throw Failure.invalid("Unknown status “\(s)”. Use up_next, watching or watched.")
        }
    }

    private func opinion(_ s: String) throws -> Opinion {
        switch s.lowercased().replacingOccurrences(of: " ", with: "_") {
        case "liked", "like", "thumbs_up", "up": return .liked
        case "disliked", "dislike", "thumbs_down", "down", "not_for_me": return .disliked
        case "none", "clear", "unrated": return .none
        default: throw Failure.invalid("Unknown opinion “\(s)”. Use liked, disliked or none.")
        }
    }

    private func platform(_ s: String) throws -> Platform {
        guard let p = Platform.normalize(s) else {
            throw Failure.invalid("Unknown service “\(s)”. Use one of: \(Self.platformNames.joined(separator: ", ")).")
        }
        return p
    }

    private func genre(_ s: String) throws -> Genre {
        let q = s.lowercased()
        if let g = Genre.allCases.first(where: { $0.rawValue.lowercased() == q })
            ?? Genre.allCases.first(where: { $0.tmdbNames.contains { $0.lowercased() == q } })
            ?? Genre.allCases.first(where: { $0.rawValue.lowercased().contains(q) }) { return g }
        throw Failure.invalid("Unknown genre “\(s)”. Use one of: \(Self.genreNames.joined(separator: ", ")).")
    }

    private func isSeries(_ s: String) throws -> Bool {
        switch s.lowercased() {
        case "series", "tv", "show", "tv_show", "shows": return true
        case "movie", "movies", "film": return false
        default: throw Failure.invalid("Unknown type “\(s)”. Use movie or series.")
        }
    }

    private func parseID(_ s: String) throws -> (String, Int) {
        let parts = s.lowercased().split(separator: ":")
        guard parts.count == 2, let id = Int(parts[1]) else { throw Failure.invalid("Ids look like \"tv:1396\" or \"movie:27205\".") }
        let type = parts[0] == "series" ? "tv" : String(parts[0])
        guard type == "tv" || type == "movie" else { throw Failure.invalid("Ids look like \"tv:1396\" or \"movie:27205\".") }
        return (type, id)
    }

    /// A library title by id ("tv:1396") or by name (exact, else a unique partial match).
    private func find(_ a: [String: Any]) throws -> Title {
        guard let key = string(a, "title") else { throw Failure.invalid("title is required.") }
        let list = try allTitles()
        if let (type, id) = try? parseID(key), let t = list.first(where: { $0.mediaType == type && $0.tmdbID == id }) { return t }
        let exact = list.filter { $0.name.compare(key, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 {
            throw Failure.invalid("Several titles are called “\(key)”: " + exact.map { "\($0.name) (\($0.year.map(String.init) ?? "?"), \($0.mediaType):\($0.tmdbID))" }.joined(separator: "; ") + ". Use the id.")
        }
        let partial = list.filter { $0.name.localizedCaseInsensitiveContains(key) }
        if partial.count == 1 { return partial[0] }
        if partial.isEmpty { throw Failure.invalid("No title matching “\(key)” is in the library.") }
        throw Failure.invalid("“\(key)” matches several titles: " + partial.prefix(8).map { "\($0.name) (\($0.mediaType):\($0.tmdbID))" }.joined(separator: "; ") + ". Use the id.")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
