import Foundation
import AppKit
import SwiftData
import UserNotifications
import ServiceManagement

/// Notifies you about titles in your library: a new season starting soon or today, a season being
/// announced, or something on your list newly streaming on a major service.
///
/// Once a day (while the app is open, or in the background if it opens at login) every relevant
/// title is refreshed from TMDB and compared with what was stored before. The first check only
/// records how things are now, so turning alerts on doesn't flood you. Each alert is sent once.
@MainActor
@Observable
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertCenter()

    // MARK: Settings

    var enabled: Bool = UserDefaults.standard.bool(forKey: "alertsEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "alertsEnabled")
            if enabled { Task { await requestPermission(); await checkIfDue() } }
        }
    }
    var seasonAlerts: Bool = UserDefaults.standard.object(forKey: "alertsSeasons") as? Bool ?? true {
        didSet { UserDefaults.standard.set(seasonAlerts, forKey: "alertsSeasons") }
    }
    var streamingAlerts: Bool = UserDefaults.standard.object(forKey: "alertsStreaming") as? Bool ?? true {
        didSet { UserDefaults.standard.set(streamingAlerts, forKey: "alertsStreaming") }
    }

    /// Opens Binge Library (without a window) when you log in, so the daily check keeps running.
    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval }
        set {
            UserDefaults.standard.set(newValue, forKey: "openAtLogin")
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { loginItemError = error.localizedDescription }
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    /// Keeps the login item matching your choice, for example after the app is reinstalled.
    private func syncLoginItem() {
        guard UserDefaults.standard.bool(forKey: "openAtLogin"), SMAppService.mainApp.status == .notRegistered else { return }
        do { try SMAppService.mainApp.register() } catch { loginItemError = error.localizedDescription }
        loginItemStatus = SMAppService.mainApp.status
    }
    private(set) var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status
    private(set) var loginItemError: String?

    // MARK: State

    private(set) var permission: UNAuthorizationStatus = .notDetermined
    private(set) var checking = false
    private(set) var progress: Double = 0
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "alertsLastCheck") as? Date
    private(set) var lastResult: String?

    private var model: AppModel?
    private var context: ModelContext?
    private var timer: Timer?
    private static let interval: TimeInterval = 20 * 3600

    // MARK: Setup

    func attach(model: AppModel, context: ModelContext) {
        self.model = model
        self.context = context
        UNUserNotificationCenter.current().delegate = self
        syncLoginItem()
        Task {
            await refreshPermission()
            // Alerts are on but macOS hasn't asked yet: ask now, so notifications can be shown.
            if enabled && permission == .notDetermined { await requestPermission() }
        }
        timer?.invalidate()
        // Look every 30 minutes whether a day has passed since the last check.
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            Task { @MainActor in await AlertCenter.shared.checkIfDue() }
        }
        Task {
            try? await Task.sleep(for: .seconds(20))   // let the app settle after launch
            await checkIfDue()
        }
    }

    func refreshPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        loginItemStatus = SMAppService.mainApp.status
    }

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshPermission()
    }

    func checkIfDue() async {
        guard enabled, !checking else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
        await check()
    }

    // MARK: The check

    struct Alert {
        var key: String
        var titleID: String
        var title: String
        var body: String
        var poster: String?
    }

    /// Refreshes the titles that can produce alerts, compares, and sends what's new.
    func check() async {
        guard let model, let context, model.hasTMDB, !checking else { return }
        checking = true
        progress = 0
        defer { checking = false }

        let all = (try? context.fetch(FetchDescriptor<Title>())) ?? []
        let finished: Set<String> = ["Ended", "Canceled"]
        let candidates = all.filter { t in
            (seasonAlerts && t.isTV && !finished.contains(t.showStatus ?? "")) || (streamingAlerts && (t.status != .watched || t.partlyWatched))
        }
        let baseline = !UserDefaults.standard.bool(forKey: "alertsBaselineDone")
        var alerts: [Alert] = []

        // Refresh four at a time; compare each title with what was stored before.
        var next = 0, done = 0
        await withTaskGroup(of: Void.self) { group in
            func launch() {
                guard next < candidates.count else { return }
                let t = candidates[next]
                next += 1
                group.addTask { @MainActor in
                    let oldStreaming = Set(t.streamingRaw)
                    let oldSeasons = t.seasons
                    guard (try? await model.refresh(t)) != nil else { return }
                    guard !baseline else { return }
                    alerts += self.changeAlerts(t, oldStreaming: oldStreaming, oldSeasons: oldSeasons)
                }
            }
            for _ in 0..<min(4, candidates.count) { launch() }
            while await group.next() != nil {
                done += 1
                progress = Double(done) / Double(max(candidates.count, 1))
                launch()
            }
        }
        try? context.save()

        // Premieres are about dates, not changes, so they're checked on every run (including the first).
        if seasonAlerts { alerts += all.flatMap(premiereAlerts) }

        // Everything found goes in the Updates page, so a dismissed notification is never lost.
        UpdatesStore.shared.record(alerts)
        let fresh = alerts.filter { !alreadySent($0.key) }
        await deliver(fresh)
        UserDefaults.standard.set(true, forKey: "alertsBaselineDone")
        lastCheck = Date()
        UserDefaults.standard.set(lastCheck, forKey: "alertsLastCheck")
        lastResult = baseline
            ? "First check done: \(candidates.count) titles are being watched for news."
            : fresh.isEmpty ? "Nothing new." : "\(fresh.count) alert\(fresh.count == 1 ? "" : "s") sent."
    }

    private func changeAlerts(_ t: Title, oldStreaming: Set<String>, oldSeasons: Int?) -> [Alert] {
        let id = "\(t.mediaType):\(t.tmdbID)"
        var out: [Alert] = []
        if streamingAlerts && (t.status != .watched || t.partlyWatched) {
            let added = Set(t.streamingRaw).subtracting(oldStreaming).sorted()
            for service in added {
                let wasPaidOnly = oldStreaming.isEmpty
                out.append(Alert(key: "\(id):stream:\(service)", titleID: id,
                                 title: "Now streaming on \(service)",
                                 body: "\(t.name) is now included with \(service)" + (wasPaidOnly ? ". Before, it was rent or buy only." : "."),
                                 poster: t.posterURL))
            }
        }
        if seasonAlerts && t.isTV, let before = oldSeasons, let now = t.seasons, now > before {
            out.append(Alert(key: "\(id):season\(now):announced", titleID: id,
                             title: "\(t.name): Season \(now) announced",
                             body: t.nextSeason == now && t.nextEpisodeNumber == 1 && t.nextAirDate != nil
                                ? "It starts \(Self.dayText(t.nextAirDate!))."
                                : "A new season is on the way.",
                             poster: t.posterURL))
        }
        return out
    }

    /// Season premieres within the next week, and on the day itself.
    private func premiereAlerts(_ t: Title) -> [Alert] {
        guard t.isTV, t.nextEpisodeNumber == 1, let season = t.nextSeason, let date = t.nextAirDate else { return [] }
        let id = "\(t.mediaType):\(t.tmdbID)"
        let days = Self.daysUntil(date)
        let newShow = season == 1
        if days == 0 {
            return [Alert(key: "\(id):s\(season):today", titleID: id,
                          title: newShow ? "\(t.name) premieres today" : "\(t.name): Season \(season) is out today",
                          body: t.watchPlatforms.first.map { "Watch it on \($0.rawValue)." } ?? "The new season starts today.",
                          poster: t.posterURL)]
        }
        if (1...7).contains(days) {
            return [Alert(key: "\(id):s\(season):week", titleID: id,
                          title: newShow ? "\(t.name) premieres \(Self.dayText(date))" : "\(t.name): Season \(season) starts \(Self.dayText(date))",
                          body: newShow ? (days == 1 ? "The new show starts tomorrow." : "The new show starts in \(days) days.")
                                        : (days == 1 ? "The new season premieres tomorrow." : "The new season premieres in \(days) days."),
                          poster: t.posterURL)]
        }
        return []
    }

    // MARK: Delivery

    private func alreadySent(_ key: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: "alertsSent") ?? []).contains(key)
    }

    private func markSent(_ keys: [String]) {
        var sent = UserDefaults.standard.stringArray(forKey: "alertsSent") ?? []
        sent.append(contentsOf: keys)
        UserDefaults.standard.set(Array(sent.suffix(3000)), forKey: "alertsSent")
    }

    private func deliver(_ alerts: [Alert]) async {
        guard !alerts.isEmpty else { return }
        #if DEBUG
        // -BLAlertsDryRun <path>: write alerts to a file instead of showing them.
        if let path = UserDefaults.standard.string(forKey: "BLAlertsDryRun") {
            let text = alerts.map { "\($0.title) | \($0.body) | \($0.titleID)" }.joined(separator: "\n") + "\n"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        #endif
        await refreshPermission()
        // Only count an alert as sent once it can actually be shown; otherwise it's tried again next check.
        guard permission == .authorized || permission == .provisional else { return }
        markSent(alerts.map(\.key))
        // More than five at once is noise: show four, then one summary.
        let shown = alerts.count > 5 ? Array(alerts.prefix(4)) : alerts
        for a in shown {
            let content = UNMutableNotificationContent()
            content.title = a.title
            content.body = a.body
            content.sound = .default
            content.threadIdentifier = "binge-library-alerts"
            content.userInfo = ["title": a.titleID]
            if let attachment = await posterAttachment(a) { content.attachments = [attachment] }
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: a.key, content: content, trigger: nil))
        }
        if alerts.count > 5 {
            let content = UNMutableNotificationContent()
            content.title = "\(alerts.count - 4) more updates in your library"
            content.body = alerts.dropFirst(4).prefix(6).map { $0.title }.joined(separator: " · ")
            content.threadIdentifier = "binge-library-alerts"
            content.userInfo = ["updates": true]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// The poster as a small image on the notification.
    private func posterAttachment(_ a: Alert) async -> UNNotificationAttachment? {
        guard let s = a.poster?.tmdbSize("w185"), let url = URL(string: s),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("binge-alert-\(UUID().uuidString).jpg")
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "poster", url: file)
    }

    // MARK: Notification clicks

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["title"] as? String
        let key = response.notification.request.identifier
        Task { @MainActor in
            UpdatesStore.shared.setRead(key)
            AlertCenter.shared.open(id)
            completionHandler()
        }
    }

    /// Opens the title's page (clicking a notification).
    private func open(_ titleID: String?) {
        guard let model, let context else { return }
        NSApp.activate()
        model.openMainWindow?()
        // The summary of many alerts opens the Updates page.
        guard let titleID else { model.selection = .updates; return }
        let parts = titleID.split(separator: ":")
        guard parts.count == 2, let tmdbID = Int(parts[1]) else { return }
        let type = String(parts[0])
        if let t = try? context.fetch(FetchDescriptor<Title>(predicate: #Predicate { $0.tmdbID == tmdbID && $0.mediaType == type })).first {
            if model.addPresented { model.closeAdd() }
            model.openDetail(.title(t.persistentModelID))
        }
    }

    // MARK: Dates

    /// Calendar days from today to an air date (TMDB dates are stored at noon UTC).
    nonisolated static func daysUntil(_ date: Date) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        let local = Calendar.current
        guard let airDay = local.date(from: parts) else { return Int.max }
        return local.dateComponents([.day], from: local.startOfDay(for: Date()), to: airDay).day ?? Int.max
    }

    /// "today", "tomorrow", "Friday" (within a week) or "March 14".
    nonisolated static func dayText(_ date: Date) -> String {
        let days = daysUntil(date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        let day = Calendar.current.date(from: parts) ?? date
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case 2...6: return day.formatted(.dateTime.weekday(.wide))
        default: return day.formatted(.dateTime.month(.wide).day())
        }
    }
}
