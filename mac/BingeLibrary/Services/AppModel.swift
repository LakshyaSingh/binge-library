import Foundation
import SwiftUI
import SwiftData
import AppKit

enum SidebarItem: Hashable {
    case forYou
    case updates
    case review
    case status(WatchStatus)
    case all
    case platform(Platform)
}

/// What the full-page detail view is showing.
enum DetailItem: Equatable {
    case title(PersistentIdentifier)
    case preview(TMDBResult)
}

/// One title found in a screenshot. A single screenshot can contain many (lists, Netflix rows…).
@Observable
final class FoundTitle: Identifiable {
    enum State: Equatable { case ready, adding, added, alreadyInLibrary, failed(String) }
    let id = UUID()
    let query: String
    let featured: Bool
    let candidates: [TMDBResult]
    var pick = 0
    var include: Bool
    var state: State = .ready
    /// Same title was already found in another screenshot in this batch.
    var duplicateInBatch = false

    init(query: String, featured: Bool, candidates: [TMDBResult], include: Bool) {
        self.query = query
        self.featured = featured
        self.candidates = candidates
        self.include = include
    }

    var match: TMDBResult? { candidates.indices.contains(pick) ? candidates[pick] : nil }
    var key: String? { match?.id }
    var isDone: Bool { state == .added || state == .alreadyInLibrary }
}

/// One screenshot in the review list.
@Observable
final class ReviewItem: Identifiable {
    enum State: Equatable { case queued, working, ready, skipped, failed(String) }
    let id = UUID()
    let data: Data
    /// Decoded in the background after the item appears, so dropping many screenshots doesn't stall the app.
    var thumbnail: NSImage?
    var state: State = .queued
    var method: RecognitionResult.Method = .textRecognition
    var notes: [String] = []
    var detectedText: String?
    var found: [FoundTitle] = []
    var platform: Platform?

    init(data: Data) {
        self.data = data
    }

    @MainActor func loadThumbnail() async {
        let data = self.data
        let image = await Task.detached(priority: .utility) { ImageUtils.thumbnail(from: data) }.value
        thumbnail = image
    }

    var selected: [FoundTitle] { found.filter { $0.include && $0.state == .ready && $0.match != nil } }
    var allDone: Bool { !found.isEmpty && found.allSatisfy { $0.isDone || !$0.include } && found.contains { $0.isDone } }
}

enum AddOutcome {
    case added(Title)
    case alreadyInLibrary(Title)
    var title: Title {
        switch self { case .added(let t), .alreadyInLibrary(let t): t }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var tmdbKey: String = Keychain.get("tmdb") ?? ""
    var geminiKey: String = Keychain.get("gemini") ?? ""
    var selection: SidebarItem? = .status(.want)
    var reviewItems: [ReviewItem] = []
    var lastError: String?
    /// Opens the main window if it's closed (set at launch by WindowCommands).
    var openMainWindow: (() -> Void)?
    /// Bumped by Edit ▸ Find (⌘F) to put the cursor in the toolbar search field.
    var focusSearchRequest = 0
    /// Bumped by View ▸ Refresh Recommendations (⌘R).
    var refreshRecommendationsRequest = 0

    /// Back (⌘[): closes whichever page is on top.
    var canGoBack: Bool { detail != nil || addPresented }
    func goBack() {
        if detail != nil { closeDetail() } else if addPresented { closeAdd() }
    }

    /// Selecting several library titles to change or remove them at once.
    var selecting = false
    var selectedTitles: Set<PersistentIdentifier> = []

    func toggleSelecting() {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
            selecting.toggle()
            if !selecting { selectedTitles = [] }
        }
    }

    func toggleSelected(_ id: PersistentIdentifier) {
        withAnimation(.spring(duration: 0.3, bounce: 0.35)) {
            if !selecting { selecting = true }
            if selectedTitles.contains(id) { selectedTitles.remove(id) } else { selectedTitles.insert(id) }
        }
    }

    /// Full-screen trailer window.
    var theater: TheaterItem?
    var openTrailerWindow: (() -> Void)?

    /// The toolbar search field: filters the library, or searches TMDB on the Add page.
    var librarySearch = ""
    var titleSearch = ""

    /// Add page, opened with the + button.
    var addPresented = false
    static let pageSpring = Animation.spring(duration: 0.5, bounce: 0.14)

    func openAdd() {
        if detail != nil { closeDetail() }
        withAnimation(Self.motion) { addPresented = true }
    }

    func closeAdd() {
        withAnimation(Self.motion) { addPresented = false }
    }

    /// Full-page detail view. `detailAnchor` is where it zooms from and back to.
    var detail: DetailItem?
    var detailAnchor: UnitPoint = .center

    func openDetail(_ item: DetailItem, from anchor: UnitPoint = .center) {
        detailAnchor = anchor
        withAnimation(Self.motion) { detail = item }
    }

    func closeDetail() {
        withAnimation(Self.motion) { detail = nil }
    }

    private var pending: [ReviewItem] = []
    private var active = 0
    private let concurrency = 2
    /// Titles currently being added, so two quick adds can't create a duplicate.
    private var addingKeys: Set<String> = []

    var hasTMDB: Bool { !tmdbKey.isEmpty }
    var hasGemini: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "BLNoGemini") { return false }
        #endif
        return !geminiKey.isEmpty
    }
    var tmdb: TMDBClient { TMDBClient(key: tmdbKey) }
    var pendingReviewCount: Int { reviewItems.filter { $0.state == .ready }.reduce(0) { $0 + $1.selected.count } }

    func saveKeys(tmdb: String? = nil, gemini: String? = nil) {
        if let tmdb { tmdbKey = tmdb.trimmingCharacters(in: .whitespacesAndNewlines); Keychain.set(tmdbKey, for: "tmdb") }
        if let gemini { geminiKey = gemini.trimmingCharacters(in: .whitespacesAndNewlines); Keychain.set(geminiKey, for: "gemini") }
    }

    // MARK: Screenshot queue

    func enqueue(_ images: [Data]) {
        guard !images.isEmpty else { return }
        let items = images.map(ReviewItem.init)
        if detail != nil { closeDetail() }
        if !addPresented { openAdd() }
        withAnimation(.spring(duration: 0.45, bounce: 0.2)) {
            reviewItems.insert(contentsOf: items, at: 0)
        }
        pending.append(contentsOf: items)
        pump()
        Task { for item in items { await item.loadThumbnail() } }
    }

    func enqueue(urls: [URL]) {
        // Read the files off the main thread; a folder of screenshots can be hundreds of megabytes.
        Task {
            let images = await Task.detached(priority: .userInitiated) {
                urls.compactMap { url -> Data? in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: url)
                }
            }.value
            enqueue(images)
        }
    }

    /// Keys of titles already in the library; set by the view that owns the SwiftData query.
    var libraryKeys: Set<String> = []

    private func pump() {
        while active < concurrency, !pending.isEmpty {
            let item = pending.removeFirst()
            active += 1
            item.state = .working
            let recognizer = Recognizer(tmdb: tmdb, geminiKey: hasGemini ? geminiKey : nil)
            Task {
                defer { active -= 1; pump() }
                do {
                    let result = try await recognizer.recognize(item.data)
                    let found = makeFound(result, excluding: item)
                    withAnimation(.spring(duration: 0.45, bounce: 0.18)) {
                        item.method = result.method
                        item.notes = result.notes
                        item.detectedText = result.detectedTitle
                        item.platform = result.platform
                        item.found = found
                        item.state = .ready
                    }
                } catch {
                    withAnimation(.smooth) { item.state = .failed(error.localizedDescription) }
                }
            }
        }
    }

    /// Turn recognition results into review rows, skipping titles already in the library
    /// or already found in another screenshot of this batch.
    private func makeFound(_ result: RecognitionResult, excluding item: ReviewItem) -> [FoundTitle] {
        let elsewhere = Set(reviewItems.filter { $0 !== item && $0.state != .skipped }
            .flatMap { $0.found.filter { !$0.duplicateInBatch }.compactMap(\.key) })
        var seen = Set<String>()
        var out: [FoundTitle] = []
        for t in result.titles {
            guard let first = t.candidates.first, seen.insert(first.id).inserted else { continue }
            let inLibrary = libraryKeys.contains(first.id)
            let dupe = elsewhere.contains(first.id)
            let f = FoundTitle(query: t.query, featured: t.featured, candidates: t.candidates,
                               include: !inLibrary && !dupe && t.confident)
            f.duplicateInBatch = dupe
            if inLibrary { f.state = .alreadyInLibrary }
            out.append(f)
        }
        return out
    }

    func clearFinishedReviews() {
        reviewItems.removeAll { $0.state == .skipped || $0.allDone || ($0.state == .ready && $0.found.isEmpty) }
    }

    /// Add the selected titles from one screenshot, four at a time (each waits on TMDB for details).
    func addSelected(from item: ReviewItem, context: ModelContext) async {
        let list = item.selected
        let platform = item.platform
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func launch() {
                guard next < list.count else { return }
                let f = list[next]
                next += 1
                group.addTask { @MainActor in await self.add(f, platform: platform, context: context) }
            }
            for _ in 0..<min(4, list.count) { launch() }
            while await group.next() != nil { launch() }
        }
    }

    func add(_ f: FoundTitle, platform: Platform?, context: ModelContext) async {
        guard let match = f.match else { return }
        withAnimation(.smooth(duration: 0.2)) { f.state = .adding }
        do {
            let outcome = try await add(match, spottedOn: platform, source: "screenshot", context: context)
            withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
                if case .alreadyInLibrary = outcome { f.state = .alreadyInLibrary } else { f.state = .added }
            }
        } catch {
            withAnimation(.smooth) { f.state = .failed(error.localizedDescription) }
        }
    }

    // MARK: Library

    /// Add a title, unless it's already in the library (or being added right now).
    @discardableResult
    func add(_ r: TMDBResult, spottedOn: Platform?, source: String, context: ModelContext) async throws -> AddOutcome {
        let id = r.tmdbID, type = r.mediaType, key = r.id
        func existing() throws -> Title? {
            try context.fetch(FetchDescriptor<Title>(predicate: #Predicate { $0.tmdbID == id && $0.mediaType == type })).first
        }
        // Duplicate check before any network work…
        if let t = try existing() {
            if t.platform == nil, let spottedOn { t.platform = spottedOn }
            return .alreadyInLibrary(t)
        }
        // …and guard against the same title being added twice at once.
        while addingKeys.contains(key) { try await Task.sleep(for: .milliseconds(100)) }
        if let t = try existing() { return .alreadyInLibrary(t) }
        addingKeys.insert(key)
        defer { addingKeys.remove(key) }

        let details = try await tmdb.details(type: type, id: id)
        if let t = try existing() { return .alreadyInLibrary(t) }
        let title = Title(tmdbID: id, mediaType: type, name: details.title)
        title.apply(details)
        title.platform = spottedOn
        title.source = source
        context.insert(title)
        try? context.save()
        return .added(title)
    }

    func refresh(_ title: Title) async throws {
        title.apply(try await tmdb.details(type: title.mediaType, id: title.tmdbID))
    }
}
