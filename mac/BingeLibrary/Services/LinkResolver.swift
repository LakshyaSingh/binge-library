import Foundation
import AppKit

/// Finds the exact page for a title on each streaming service, so "Open in …" lands on the
/// show or movie itself instead of a search.
///
/// TMDB's API only gives a link to its own "where to watch" page. That page (powered by JustWatch)
/// links out to every service, and each outbound link carries the service's own address for the title.
/// We read those once per title and cache them; anything we can't resolve falls back to search.
@MainActor
@Observable
final class LinkResolver {
    static let shared = LinkResolver()

    /// "tv:95396" → provider name (normalized like TMDBClient's) → URL.
    private(set) var links: [String: [String: String]] = [:]
    private var cache: [String: Entry] = LinkResolver.loadCache()
    private var loading: [String: Task<Void, Never>] = [:]

    struct Entry: Codable {
        var date: Date
        var links: [String: String]
    }

    private static let lifetime: TimeInterval = 7 * 24 * 3600
    private static let emptyLifetime: TimeInterval = 24 * 3600

    /// The exact page for a provider, if known.
    func url(for provider: String, type: String, id: Int) -> URL? {
        let key = "\(type):\(id)"
        let name = TMDBClient.normalizeProvider(provider)
        return (links[key]?[name] ?? cache[key]?.links[name]).flatMap(URL.init(string:))
    }

    /// Fetch the links for a title unless they're cached and fresh.
    func load(type: String, id: Int, name: String) async {
        let key = "\(type):\(id)"
        if let hit = cache[key] {
            let age = Date().timeIntervalSince(hit.date)
            if age < (hit.links.isEmpty ? Self.emptyLifetime : Self.lifetime) {
                if links[key] == nil { links[key] = hit.links }
                return
            }
        }
        if let running = loading[key] { await running.value; return }
        let task = Task {
            guard let found = await Self.fetch(type: type, id: id, name: name) else { return }   // network error: try again next time
            cache[key] = Entry(date: Date(), links: found)
            links[key] = found
            save()
        }
        loading[key] = task
        await task.value
        loading[key] = nil
    }

    /// Open a title on a service: its exact page when we can find it, otherwise the service's search.
    func open(_ platform: Platform, type: String, id: Int, name: String) async {
        if url(for: platform.rawValue, type: type, id: id) == nil {
            // Don't keep someone waiting on a slow network; search is a fine fallback.
            _ = await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.load(type: type, id: id, name: name) }
                group.addTask { try? await Task.sleep(for: .seconds(4)) }
                await group.next()
                group.cancelAll()
            }
        }
        if let url = url(for: platform.rawValue, type: type, id: id) ?? platform.link(for: name) {
            Self.openInBestApp(url)
        }
    }

    /// Apple TV links go to the TV app (which plays the show) rather than the default browser.
    static func openInBestApp(_ url: URL) {
        if url.host == "tv.apple.com",
           let tv = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TV") {
            NSWorkspace.shared.open([url], withApplicationAt: tv, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Fetching and parsing

    private nonisolated static func fetch(type: String, id: Int, name: String) async -> [String: String]? {
        guard let url = URL(string: "https://www.themoviedb.org/\(type)/\(id)/watch?locale=US") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(String(decoding: data, as: UTF8.self), titleName: name)
    }

    /// Each outbound link looks like click.justwatch.com/a?cx=<base64 JSON naming the provider>&r=<the service's URL>.
    nonisolated static func parse(_ html: String, titleName: String) -> [String: String] {
        let pattern = /href="(https:\/\/click\.justwatch\.com\/a\?[^"]+)"/
        var best: [String: (rank: Int, url: String)] = [:]
        for match in html.matches(of: pattern) {
            let href = String(match.output.1).replacingOccurrences(of: "&amp;", with: "&")
            guard let items = URLComponents(string: href)?.queryItems,
                  let cx = items.first(where: { $0.name == "cx" })?.value,
                  let target = items.first(where: { $0.name == "r" })?.value,
                  let info = decodeContext(cx),
                  let url = clean(target, titleName: titleName) else { continue }
            let name = TMDBClient.normalizeProvider(info.provider)
            // Subscription and free links beat rent and buy for the same service.
            let rank = ["flatrate": 0, "free": 0, "ads": 0, "rent": 1, "buy": 2][info.monetization] ?? 3
            if let current = best[name], current.rank <= rank { continue }
            best[name] = (rank, url.absoluteString)
        }
        return best.mapValues(\.url)
    }

    private nonisolated static func decodeContext(_ cx: String) -> (provider: String, monetization: String)? {
        var b64 = cx.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contexts = json["data"] as? [[String: Any]] else { return nil }
        for c in contexts {
            if let d = c["data"] as? [String: Any], let provider = d["provider"] as? String {
                return (provider, d["monetizationType"] as? String ?? "")
            }
        }
        return nil
    }

    /// Turn a service URL into the cleanest link to the title's own page.
    nonisolated static func clean(_ raw: String, titleName: String) -> URL? {
        guard var c = URLComponents(string: raw) else { return nil }
        // Affiliate wrappers carry the real address in `u`.
        if let u = c.queryItems?.first(where: { $0.name == "u" })?.value, u.hasPrefix("http"),
           let inner = URLComponents(string: u) { c = inner }
        let host = c.host ?? ""
        let query = c.queryItems ?? []
        if host == "watch.amazon.com", let gti = query.first(where: { $0.name == "gti" })?.value {
            return URL(string: "https://www.primevideo.com/detail/\(gti)")
        }
        if host == "tv.apple.com" {
            // Episode links start you at episode 1; send people to the show page instead.
            if c.path.contains("/episode/"), let show = query.first(where: { $0.name == "showId" })?.value {
                let region = c.path.split(separator: "/").first.map(String.init) ?? "us"
                return URL(string: "https://tv.apple.com/\(region)/show/\(slug(titleName))/\(show)")
            }
            c.queryItems = nil   // drop affiliate tracking
            return c.url
        }
        return c.url
    }

    private nonisolated static func slug(_ s: String) -> String {
        let parts = s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return parts.isEmpty ? "title" : parts.joined(separator: "-")
    }

    // MARK: Disk cache

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("title-links.json")
    }

    private static func loadCache() -> [String: Entry] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.cacheURL, options: .atomic) }
    }
}
