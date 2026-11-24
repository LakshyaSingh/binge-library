import Foundation
import SwiftData

struct ProviderInfo: Codable, Hashable {
    var name: String
    var logoURL: String?
}

struct WatchProviders: Codable, Hashable {
    var stream: [ProviderInfo] = []
    var rent: [ProviderInfo] = []
    var buy: [ProviderInfo] = []
    var link: String?
    var isEmpty: Bool { stream.isEmpty && rent.isEmpty && buy.isEmpty }
}

enum WatchStatus: String, CaseIterable, Identifiable {
    case want, watching, watched
    var id: String { rawValue }
    var label: String {
        switch self {
        case .want: "Up Next"
        case .watching: "Watching"
        case .watched: "Watched"
        }
    }
    var symbol: String {
        switch self {
        case .want: "list.bullet"
        case .watching: "play.circle"
        case .watched: "checkmark.circle"
        }
    }
}

/// Your opinion of a title. Disliked titles aren't used for recommendations; liked ones count extra.
enum Opinion: String, CaseIterable, Identifiable {
    case none, liked, disliked
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "No Rating"
        case .liked: "I Like This"
        case .disliked: "Not for Me"
        }
    }
    var symbol: String {
        switch self {
        case .none: "hand.thumbsup.slash"
        case .liked: "hand.thumbsup.fill"
        case .disliked: "hand.thumbsdown.fill"
        }
    }
}

/// A movie or show in the library.
/// Every property has a default and nothing is marked unique, so the model stays
/// compatible with CloudKit if iCloud sync is turned on later.
@Model
final class Title {
    var tmdbID: Int = 0
    var mediaType: String = "movie"   // "movie" or "tv"
    var name: String = ""
    var year: Int?
    var posterURL: String?
    var backdropURL: String?
    var overview: String = ""
    var tagline: String = ""
    var genres: [String] = []
    var rating: Double?
    var runtime: Int?
    var seasons: Int?
    var providersData: Data?
    /// Major platforms streaming this title, stored so filters and counts never decode JSON while drawing.
    var streamingRaw: [String] = []
    var region: String = "US"
    var statusRaw: String = WatchStatus.want.rawValue
    var spottedOn: String?
    var source: String = "search"     // "screenshot" or "search"
    var addedAt: Date = Date()
    var refreshedAt: Date?
    /// YouTube key of the title's trailer, and whether we've looked it up yet.
    var trailerKey: String?
    var trailerChecked: Bool = false
    /// Thumbs up or down (Opinion.rawValue).
    var opinionRaw: String = Opinion.none.rawValue
    /// When it was marked Watched (for Year in Review). Titles marked before this existed have none.
    var watchedAt: Date?
    /// Series: number of episodes and typical episode length in minutes (for hours watched).
    var episodeCount: Int?
    var episodeRuntime: Int?
    /// Series: the next episode to air, and TMDB's status ("Returning Series", "Ended"…), for alerts.
    var nextAirDate: Date?
    var nextSeason: Int?
    var nextEpisodeNumber: Int?
    var showStatus: String?
    /// Series: how many seasons you've watched, counted from Season 1. A show you've watched part of
    /// is in both Watched and Up Next; when a new season comes out, a finished show is back in Up Next.
    var seasonsWatched: Int = 0

    init(tmdbID: Int, mediaType: String, name: String) {
        self.tmdbID = tmdbID
        self.mediaType = mediaType
        self.name = name
    }

    var status: WatchStatus {
        get { WatchStatus(rawValue: statusRaw) ?? .want }
        set {
            if newValue == .watched && status != .watched { watchedAt = Date() }
            if newValue != .watched { watchedAt = nil }
            // Marking a show Watched means every season so far; Up Next means starting from the beginning.
            if isTV && newValue == .watched { seasonsWatched = max(seasonsWatched, seasons ?? 0) }
            if isTV && newValue == .want { seasonsWatched = 0 }
            statusRaw = newValue.rawValue
        }
    }

    /// Seasons you haven't watched yet, once you've watched at least one (nil otherwise).
    var seasonsLeft: Int? {
        guard isTV, seasonsWatched > 0, let total = seasons, total > seasonsWatched else { return nil }
        return total - seasonsWatched
    }

    /// Watched some seasons, with more to go.
    var partlyWatched: Bool { seasonsLeft != nil }

    /// Whether the title belongs in a library list. Partly watched shows are in both Watched and Up Next.
    func isIn(_ list: WatchStatus) -> Bool {
        switch list {
        case .want: status == .want || (partlyWatched && status != .watching)
        case .watching: status == .watching
        case .watched: status == .watched || (isTV && seasonsWatched > 0)
        }
    }

    /// Records seasons 1…n as watched. All of them makes the show Watched; fewer keeps it in Up Next too.
    func markSeasons(_ n: Int) {
        let total = seasons ?? n
        let n = min(max(n, 0), max(total, n))
        if n >= total && n > 0 {
            if status != .watched { watchedAt = Date() }
            statusRaw = WatchStatus.watched.rawValue
        } else if status == .watched {
            watchedAt = nil
            statusRaw = WatchStatus.want.rawValue
        }
        seasonsWatched = n
    }

    /// "S1", "S1–2" for the seasons watched so far.
    var seasonsWatchedShort: String? {
        guard isTV, seasonsWatched > 0 else { return nil }
        return seasonsWatched == 1 ? "S1" : "S1–\(seasonsWatched)"
    }

    /// "Season 3 is next", "Seasons 3–4 left", or nil when there's nothing in progress.
    var seasonProgressText: String? {
        guard let left = seasonsLeft else { return nil }
        let next = seasonsWatched + 1
        return left == 1 ? "Season \(next) is next" : "Seasons \(next)–\(next + left - 1) to watch"
    }

    /// When it counts as watched for Year in Review: the date it was marked, or (for titles marked
    /// Watched before dates were recorded) the day it was added.
    var watchedDate: Date? { status == .watched ? (watchedAt ?? addedAt) : nil }

    /// Rough minutes to watch the whole thing: a movie's runtime, or every episode of a series.
    var totalMinutes: Int? {
        if isTV {
            guard let n = episodeCount, n > 0 else { return nil }
            return n * (episodeRuntime ?? 45)
        }
        return runtime
    }

    var opinion: Opinion {
        get { Opinion(rawValue: opinionRaw) ?? .none }
        set { opinionRaw = newValue.rawValue }
    }

    var platform: Platform? {
        get { Platform.normalize(spottedOn) }
        set { spottedOn = newValue?.rawValue }
    }

    var providers: WatchProviders {
        get { providersData.flatMap { try? JSONDecoder().decode(WatchProviders.self, from: $0) } ?? WatchProviders() }
        set {
            providersData = try? JSONEncoder().encode(newValue)
            streamingRaw = newValue.stream.compactMap { Platform.exact($0.name)?.rawValue }
        }
    }

    var isTV: Bool { mediaType == "tv" }

    /// Platform it was spotted on plus every major service streaming it.
    var allPlatforms: Set<Platform> {
        var set = Set(streamingRaw.compactMap(Platform.exact))
        if let p = platform { set.insert(p) }
        return set
    }

    func apply(_ d: TMDBDetails) {
        name = d.title
        year = d.year
        posterURL = d.posterURL
        backdropURL = d.backdropURL
        overview = d.overview
        tagline = d.tagline
        genres = d.genres
        rating = d.rating
        runtime = d.runtime
        seasons = d.seasons
        providers = d.providers
        region = d.region
        trailerKey = d.trailerKey
        trailerChecked = true
        episodeCount = d.episodeCount
        episodeRuntime = d.episodeRuntime
        nextAirDate = d.nextEpisode?.airDate
        nextSeason = d.nextEpisode?.season
        nextEpisodeNumber = d.nextEpisode?.episode
        showStatus = d.showStatus
        refreshedAt = Date()
    }
}
