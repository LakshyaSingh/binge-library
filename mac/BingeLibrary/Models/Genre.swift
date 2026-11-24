import Foundation

/// Genres for filtering, grouped the way streaming services present them.
///
/// TMDB uses different genre lists for movies and TV (TV has no "Thriller" or "Romance"; it has
/// "Sci-Fi & Fantasy" where movies have "Science Fiction" and "Fantasy"), so each group lists the
/// TMDB genre names and IDs from both lists that belong in it.
enum Genre: String, CaseIterable, Identifiable {
    case action = "Action & Adventure"
    case animation = "Animation"
    case comedy = "Comedy"
    case crime = "Crime"
    case documentary = "Documentary"
    case drama = "Drama"
    case family = "Family & Kids"
    case sciFi = "Sci-Fi & Fantasy"
    case history = "History & War"
    case horror = "Horror"
    case music = "Music"
    case mystery = "Mystery & Thriller"
    case reality = "Reality & Talk"
    case romance = "Romance"
    case western = "Western"

    var id: String { rawValue }

    /// TMDB genre IDs (movie and TV lists) in this group.
    var tmdbIDs: Set<Int> {
        switch self {
        case .action: [28, 12, 10759]
        case .animation: [16]
        case .comedy: [35]
        case .crime: [80]
        case .documentary: [99]
        case .drama: [18]
        case .family: [10751, 10762]
        case .sciFi: [878, 14, 10765]
        case .history: [36, 10752, 10768]
        case .horror: [27]
        case .music: [10402]
        case .mystery: [9648, 53]
        case .reality: [10764, 10767, 10763, 10766]
        case .romance: [10749]
        case .western: [37]
        }
    }

    /// TMDB genre names (as stored on library titles) in this group.
    var tmdbNames: Set<String> {
        switch self {
        case .action: ["Action", "Adventure", "Action & Adventure"]
        case .animation: ["Animation"]
        case .comedy: ["Comedy"]
        case .crime: ["Crime"]
        case .documentary: ["Documentary"]
        case .drama: ["Drama"]
        case .family: ["Family", "Kids"]
        case .sciFi: ["Science Fiction", "Fantasy", "Sci-Fi & Fantasy"]
        case .history: ["History", "War", "War & Politics"]
        case .horror: ["Horror"]
        case .music: ["Music"]
        case .mystery: ["Mystery", "Thriller"]
        case .reality: ["Reality", "Talk", "News", "Soap"]
        case .romance: ["Romance"]
        case .western: ["Western"]
        }
    }

    var symbol: String {
        switch self {
        case .action: "figure.run"
        case .animation: "paintpalette"
        case .comedy: "theatermasks"
        case .crime: "magnifyingglass"
        case .documentary: "film"
        case .drama: "person.2"
        case .family: "figure.2.and.child.holdinghands"
        case .sciFi: "sparkles"
        case .history: "building.columns"
        case .horror: "moon.haze"
        case .music: "music.note"
        case .mystery: "eye"
        case .reality: "tv"
        case .romance: "heart"
        case .western: "sun.dust"
        }
    }

    func matches(names: [String]) -> Bool { names.contains { tmdbNames.contains($0) } }
    func matches(ids: [Int]) -> Bool { ids.contains { tmdbIDs.contains($0) } }

    static func groups(names: [String]) -> Set<Genre> { Set(allCases.filter { $0.matches(names: names) }) }
    static func groups(ids: [Int]) -> Set<Genre> { Set(allCases.filter { $0.matches(ids: ids) }) }
}

/// What the genre filter is set to. Stored as a string so @AppStorage can keep it; "" means all genres.
extension Genre {
    static func stored(_ raw: String) -> Genre? { Genre(rawValue: raw) }
}
