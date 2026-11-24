import Foundation

struct TMDBResult: Identifiable, Hashable, Codable {
    var tmdbID: Int
    var mediaType: String
    var title: String
    var originalTitle: String
    var year: Int?
    var posterURL: String?
    var overview: String
    var rating: Double?
    var popularity: Double
    /// TMDB genre IDs (search and recommendation results include them; nil in older caches).
    var genreIDs: [Int]? = nil
    var id: String { "\(mediaType):\(tmdbID)" }
    var isTV: Bool { mediaType == "tv" }
}

struct TMDBDetails {
    var tmdbID: Int
    var mediaType: String
    var title: String
    var year: Int?
    var posterURL: String?
    var backdropURL: String?
    var overview: String
    var tagline: String
    var genres: [String]
    var rating: Double?
    var runtime: Int?
    var seasons: Int?
    var providers: WatchProviders
    var region: String
    var trailerKey: String?
    /// Series only: episode count, typical episode length, the next episode to air, and TMDB's status.
    var episodeCount: Int? = nil
    var episodeRuntime: Int? = nil
    var nextEpisode: NextEpisode? = nil
    var showStatus: String? = nil

    struct NextEpisode {
        var airDate: Date
        var season: Int
        var episode: Int
    }
}

enum TMDBError: LocalizedError {
    case badKey, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .badKey: "TMDB rejected the API key. Check it in Settings."
        case .http(let code, let body): "TMDB error \(code): \(body.prefix(120))"
        }
    }
}

struct TMDBClient {
    let key: String
    var region = "US"

    private static let base = URL(string: "https://api.themoviedb.org/3")!
    private static let img = "https://image.tmdb.org/t/p"

    // MARK: Raw JSON

    private struct Raw: Decodable {
        var id: Int
        var mediaType: String?
        var title: String?
        var name: String?
        var originalTitle: String?
        var originalName: String?
        var releaseDate: String?
        var firstAirDate: String?
        var posterPath: String?
        var backdropPath: String?
        var overview: String?
        var voteAverage: Double?
        var popularity: Double?
        var genres: [Genre]?
        var genreIds: [Int]?
        var runtime: Int?
        var numberOfSeasons: Int?
        var numberOfEpisodes: Int?
        var episodeRunTime: [Int]?
        var nextEpisodeToAir: Episode?
        var lastEpisodeToAir: Episode?
        var status: String?
        var tagline: String?
        var watchProviders: WP?
        var videos: Videos?

        struct Genre: Decodable { var id: Int?; var name: String }
        struct Episode: Decodable { var airDate: String?; var seasonNumber: Int?; var episodeNumber: Int?; var runtime: Int? }
        struct WP: Decodable { var results: [String: Region] }
        struct Region: Decodable {
            var link: String?
            var flatrate: [P]?
            var free: [P]?
            var ads: [P]?
            var rent: [P]?
            var buy: [P]?
        }
        struct P: Decodable { var providerName: String; var logoPath: String? }
        struct Videos: Decodable { var results: [Video] }
        struct Video: Decodable {
            var key: String
            var site: String
            var type: String
            var official: Bool?
            var iso6391: String?
            var size: Int?
        }

        enum CodingKeys: String, CodingKey {
            case id, mediaType, title, name, originalTitle, originalName, releaseDate, firstAirDate
            case posterPath, backdropPath, overview, voteAverage, popularity, genres, genreIds, runtime
            case numberOfSeasons, numberOfEpisodes, episodeRunTime, nextEpisodeToAir, lastEpisodeToAir, status, tagline, videos
            case watchProviders = "watch/providers"
        }
    }

    private struct SearchResponse: Decodable { var results: [Raw] }

    // MARK: Requests

    private func get<T: Decodable>(_ path: String, _ params: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = params.filter { !$0.value.isEmpty }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request: URLRequest
        // v4 read-access tokens are long JWTs; v3 keys are 32 hex characters.
        if key.count > 40 {
            comps.queryItems = items
            request = URLRequest(url: comps.url!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else {
            items.append(URLQueryItem(name: "api_key", value: key))
            comps.queryItems = items
            request = URLRequest(url: comps.url!)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw TMDBError.badKey }
        guard (200..<300).contains(code) else { throw TMDBError.http(code, String(decoding: data, as: UTF8.self)) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    /// "2026-03-14" as a date at noon UTC (so it's the same calendar day in every US time zone).
    static func day(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH"
        return f.date(from: s + " 12")
    }

    private static func year(_ date: String?) -> Int? {
        guard let d = date, d.count >= 4 else { return nil }
        return Int(d.prefix(4))
    }

    private func result(_ r: Raw, type hint: String? = nil) -> TMDBResult {
        let type = r.mediaType ?? hint ?? "movie"
        let tv = type == "tv"
        return TMDBResult(
            tmdbID: r.id, mediaType: type,
            title: (tv ? r.name : r.title) ?? r.title ?? r.name ?? "Untitled",
            originalTitle: (tv ? r.originalName : r.originalTitle) ?? "",
            year: Self.year(tv ? r.firstAirDate : r.releaseDate),
            posterURL: r.posterPath.map { "\(Self.img)/w342\($0)" },
            overview: r.overview ?? "",
            rating: r.voteAverage.flatMap { $0 > 0 ? (($0 * 10).rounded() / 10) : nil },
            popularity: r.popularity ?? 0,
            genreIDs: r.genreIds ?? r.genres?.compactMap(\.id))
    }

    func search(_ query: String, type: String? = nil, year: Int? = nil) async throws -> [TMDBResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if let type, type == "movie" || type == "tv" {
            var params = ["query": q, "include_adult": "false"]
            if let year { params[type == "tv" ? "first_air_date_year" : "year"] = String(year) }
            var res: SearchResponse = try await get("search/\(type)", params)
            if res.results.isEmpty, year != nil {
                res = try await get("search/\(type)", ["query": q, "include_adult": "false"])
            }
            return res.results.map { result($0, type: type) }
        }
        let res: SearchResponse = try await get("search/multi", ["query": q, "include_adult": "false"])
        return res.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }.map { result($0) }
    }

    func details(type: String, id: Int) async throws -> TMDBDetails {
        let r: Raw = try await get("\(type)/\(id)", ["append_to_response": "watch/providers,videos"])
        let base = result(r, type: type)
        return TMDBDetails(
            tmdbID: id, mediaType: type, title: base.title, year: base.year,
            posterURL: base.posterURL,
            backdropURL: r.backdropPath.map { "\(Self.img)/w1280\($0)" },
            overview: base.overview, tagline: r.tagline ?? "",
            genres: (r.genres ?? []).map(\.name), rating: base.rating,
            runtime: type == "movie" ? r.runtime.flatMap { $0 > 0 ? $0 : nil } : nil,
            seasons: type == "tv" ? r.numberOfSeasons : nil,
            providers: providers(r.watchProviders), region: region,
            trailerKey: Self.bestTrailer(r.videos?.results ?? []),
            episodeCount: type == "tv" ? r.numberOfEpisodes : nil,
            episodeRuntime: type == "tv" ? (r.episodeRunTime?.first ?? r.lastEpisodeToAir?.runtime ?? r.nextEpisodeToAir?.runtime) : nil,
            nextEpisode: type == "tv" ? r.nextEpisodeToAir.flatMap { e in
                guard let d = e.airDate.flatMap(Self.day), let s = e.seasonNumber, let n = e.episodeNumber else { return nil }
                return TMDBDetails.NextEpisode(airDate: d, season: s, episode: n)
            } : nil,
            showStatus: type == "tv" ? r.status : nil)
    }

    /// Official YouTube trailer if there is one, then any trailer, then a teaser.
    private static func bestTrailer(_ videos: [Raw.Video]) -> String? {
        let yt = videos.filter { $0.site == "YouTube" }
        func score(_ v: Raw.Video) -> Int {
            var s = 0
            if v.type == "Trailer" { s += 100 } else if v.type == "Teaser" { s += 50 } else { return -1 }
            if v.official == true { s += 20 }
            if v.iso6391 == "en" { s += 10 }
            s += (v.size ?? 0) / 360
            return s
        }
        return yt.filter { score($0) >= 0 }.max { score($0) < score($1) }?.key
    }

    func trailerKey(type: String, id: Int) async throws -> String? {
        let res: Raw.Videos = try await get("\(type)/\(id)/videos")
        return Self.bestTrailer(res.results)
    }

    /// TMDB's "people who liked this also liked" list for one title.
    func recommendations(type: String, id: Int) async throws -> [TMDBResult] {
        let res: SearchResponse = try await get("\(type)/\(id)/recommendations")
        return res.results.filter { ($0.mediaType ?? type) == "movie" || ($0.mediaType ?? type) == "tv" }
            .map { result($0, type: type) }
    }

    /// Where one title is available in the region (without fetching its full details).
    func watchProviders(type: String, id: Int) async throws -> WatchProviders {
        let wp: Raw.WP = try await get("\(type)/\(id)/watch/providers")
        return providers(wp)
    }

    // MARK: Providers

    static func normalizeProvider(_ raw: String) -> String {
        // "Apple TV Amazon Channel", "Max Roku Premium Channel" → the same service.
        let name = raw.replacingOccurrences(of: #"\s+(amazon|roku premium|apple tv) channel$"#, with: "",
                                            options: [.regularExpression, .caseInsensitive])
        let rules: [(String, String)] = [
            ("^netflix", "Netflix"), ("amazon prime video|^prime video", "Prime Video"),
            ("^amazon video$", "Amazon Video"), ("^apple tv", "Apple TV"), ("^hulu", "Hulu"),
            ("^(max|hbo max)", "HBO Max"), ("^disney", "Disney+"), ("^peacock", "Peacock"), ("^paramount", "Paramount+"),
        ]
        for (pattern, label) in rules where name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return label
        }
        return name
    }

    private func providers(_ wp: Raw.WP?) -> WatchProviders {
        guard let r = wp?.results[region] else { return WatchProviders() }
        func map(_ list: [Raw.P]) -> [ProviderInfo] {
            var seen = Set<String>(), out: [ProviderInfo] = []
            for p in list {
                let name = Self.normalizeProvider(p.providerName)
                if seen.insert(name).inserted {
                    out.append(ProviderInfo(name: name, logoURL: p.logoPath.map { "\(Self.img)/w92\($0)" }))
                }
            }
            return out
        }
        return WatchProviders(
            stream: map((r.flatrate ?? []) + (r.free ?? []) + (r.ads ?? [])),
            rent: map(r.rent ?? []), buy: map(r.buy ?? []), link: r.link)
    }
}
