import Foundation

/// Every alert Binge Library has found, kept so a dismissed notification is never lost.
/// Saved as a small JSON file next to the library (not in it), newest first, up to 500 entries.
@MainActor
@Observable
final class UpdatesStore {
    static let shared = UpdatesStore()

    enum Kind: String, Codable {
        case streaming, season, premiere, other
        var symbol: String {
            switch self {
            case .streaming: "play.tv"
            case .season: "sparkles.tv"
            case .premiere: "calendar.badge.clock"
            case .other: "bell"
            }
        }
    }

    struct Item: Codable, Identifiable, Hashable {
        var id: String          // the alert's key, so each alert is logged once
        var titleID: String     // "tv:95396"
        var headline: String
        var body: String
        var poster: String?
        var date: Date
        var kind: Kind
        var read: Bool = false
    }

    private(set) var items: [Item] = []
    var unreadCount: Int { items.filter { !$0.read }.count }

    private static var url: URL {
        URL.applicationSupportDirectory.appending(path: "Binge Library", directoryHint: .isDirectory).appending(path: "updates.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? Self.decoder.decode([Item].self, from: data) {
            items = saved
        }
    }

    /// Adds alerts that aren't in the log yet. Returns how many were new.
    @discardableResult
    func record(_ alerts: [AlertCenter.Alert]) -> Int {
        let known = Set(items.map(\.id))
        let new = alerts.filter { !known.contains($0.key) }.map { a in
            Item(id: a.key, titleID: a.titleID, headline: a.title, body: a.body, poster: a.poster, date: Date(), kind: Self.kind(of: a.key))
        }
        guard !new.isEmpty else { return 0 }
        items = Array((new + items).prefix(500))
        save()
        return new.count
    }

    func setRead(_ id: String, _ read: Bool = true) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].read != read else { return }
        items[i].read = read
        save()
    }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        for i in items.indices { items[i].read = true }
        save()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private static func kind(of key: String) -> Kind {
        if key.contains(":stream:") { return .streaming }
        if key.hasSuffix(":announced") { return .season }
        if key.hasSuffix(":today") || key.hasSuffix(":week") { return .premiere }
        return .other
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    private func save() {
        guard let data = try? Self.encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}
