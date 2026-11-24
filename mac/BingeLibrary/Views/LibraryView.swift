import SwiftUI
import SwiftData

enum LibrarySort: String, CaseIterable, Identifiable {
    case added = "Recently Added", rating = "Top Rated", title = "Title", year = "Newest"
    var id: String { rawValue }
}

enum TypeFilter: String, CaseIterable, Identifiable {
    case all = "All", movie = "Movies", tv = "TV Shows"
    var id: String { rawValue }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let filter: SidebarItem
    let titles: [Title]

    @AppStorage("librarySort") private var sort: LibrarySort = .added
    @AppStorage("libraryType") private var type: TypeFilter = .all
    @AppStorage("libraryGenre") private var genre: String = ""
    @State private var pendingDelete: Title?
    @State private var confirmBulkRemove = false

    private var heading: String {
        switch filter {
        case .status(let s): s.label
        case .all: "All Titles"
        case .platform(let p): p.rawValue
        case .forYou: "For You"
        case .review: "Year in Review"
        case .updates: "Updates"
        }
    }

    private var activeGenre: Genre? { Genre(rawValue: genre) }

    /// Everything the sidebar item, type and search allow, before the genre filter.
    private var base: [Title] {
        titles.filter { t in
            let matchesFilter: Bool = switch filter {
            case .status(let s): t.isIn(s)
            case .platform(let p): t.allPlatforms.contains(p)
            default: true
            }
            let matchesType = type == .all || (type == .tv) == t.isTV
            let search = model.librarySearch
            let matchesSearch = search.isEmpty || t.name.localizedCaseInsensitiveContains(search)
            return matchesFilter && matchesType && matchesSearch
        }
    }

    private func shown(from base: [Title]) -> [Title] {
        base.filter { t in activeGenre.map { $0.matches(names: t.genres) } ?? true }
        .sorted { a, b in
            switch sort {
            case .added: a.addedAt > b.addedAt
            case .rating: (a.rating ?? 0) > (b.rating ?? 0)
            case .title: a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .year: (a.year ?? 0) > (b.year ?? 0)
            }
        }
    }

    private var covered: Bool { model.detail != nil || model.addPresented }

    var body: some View {
        let unfiltered = base
        let list = shown(from: unfiltered)
        Group {
            if titles.isEmpty {
                ContentUnavailableView {
                    Label("Your watchlist starts here", systemImage: "sparkles.tv")
                        .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 3)))
                } description: {
                    Text("Drop screenshots from Netflix, Prime Video or Apple TV anywhere in this window, or search for any movie or show.")
                } actions: {
                    Button("Add Titles") { model.openAdd() }.buttonStyle(.borderedProminent)
                }
            } else if list.isEmpty, let g = activeGenre, !unfiltered.isEmpty {
                GenreEmptyView(genre: g) { withAnimation(.spring(duration: 0.45, bounce: 0.15)) { genre = "" } }
            } else if list.isEmpty {
                ContentUnavailableView.search(text: model.librarySearch)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 22, alignment: .top)],
                              alignment: .leading, spacing: 30) {
                        ForEach(list) { title in
                            let id = title.persistentModelID
                            let isSelected = model.selectedTitles.contains(id)
                            DetailOpener(item: .title(id), accessibilityLabel: title.accessibilityDescription,
                                         selection: .init(active: model.selecting, isSelected: isSelected,
                                                          toggle: { model.toggleSelected(id) })) {
                                PosterCard(title: title, selected: model.selecting ? isSelected : nil)
                            }
                            .contextMenu {
                                // Right-clicking one of several selected titles acts on all of them.
                                if model.selecting && isSelected && model.selectedTitles.count > 1 {
                                    bulkMenu
                                } else {
                                    menu(for: title)
                                }
                            }
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    .padding(24)
                    .animation(.spring(duration: 0.45, bounce: 0.15), value: list.map(\.persistentModelID))
                }
                // ⌘A selects every title shown; Delete removes the selection (after asking).
                .onCommand(#selector(NSResponder.selectAll(_:))) { selectAll(list) }
                .onDeleteCommand { if model.selecting && !model.selectedTitles.isEmpty { confirmBulkRemove = true } }
                #if DEBUG
                .task {
                    // -BLSelectCount N selects the first N titles, for checking without a mouse.
                    let n = UserDefaults.standard.integer(forKey: "BLSelectCount")
                    if n > 0 { try? await Task.sleep(for: .seconds(1)); selectAll(Array(list.prefix(n))) }
                }
                #endif
                .onScrollPhaseChange { _, phase in
                    if ScrollActivity.shared.isScrolling != phase.isScrolling { ScrollActivity.shared.isScrolling = phase.isScrolling }
                }
                .task(id: list.count) {
                    // Warm the cache so posters are already decoded before they scroll into view.
                    await ImagePipeline.shared.prefetch(list.compactMap { $0.posterURL.flatMap(URL.init(string:)) }, maxPixel: 600)
                }
            }
        }
        .navigationTitle(covered ? "" : heading)
        .navigationSubtitle(list.isEmpty || covered ? ""
            : model.selecting ? "\(model.selectedTitles.count) of \(list.count) selected"
            : "\(list.count) \(activeGenre.map { "\($0.rawValue) " } ?? "")\(list.count == 1 ? "title" : "titles")")
        .toolbar {
            // Library controls step aside while another page is on top.
            if !covered && model.selecting {
                selectionToolbar(list)
            } else if !covered {
            ToolbarItem {
                AddButton(pending: model.pendingReviewCount) { model.openAdd() }
            }
            ToolbarItem {
                Button("Select") { model.toggleSelecting() }
                    .help("Select several titles to change or remove them at once (or ⌘-click a poster)")
                    .disabled(list.isEmpty)
            }
            ToolbarItem {
                Picker("Type", selection: $type.animation(.spring(duration: 0.4, bounce: 0.15))) {
                    ForEach(TypeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Show movies, TV shows or both")
            }
            ToolbarItem {
                GenreFilterMenu(selection: $genre, counts: Self.genreCounts(unfiltered))
            }
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $sort.animation(.spring(duration: 0.45, bounce: 0.15))) {
                        ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort titles")
            }
            }
        }
        .confirmationDialog(model.selectedTitles.count == 1 ? "Remove 1 title from your library?"
                                : "Remove \(model.selectedTitles.count) titles from your library?",
                            isPresented: $confirmBulkRemove) {
            Button("Remove", role: .destructive) { removeSelected() }
        } message: {
            Text("You can undo this with Edit ▸ Undo (⌘Z).")
        }
        .background {
            // Esc stops selecting.
            if model.selecting && !covered {
                Button("") { model.toggleSelecting() }.keyboardShortcut(.cancelAction).hidden()
            }
        }
        .onChange(of: filter) { if model.selecting { model.toggleSelecting() } }
        .confirmationDialog("Remove “\(pendingDelete?.name ?? "")” from your library?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Remove", role: .destructive) {
                if let t = pendingDelete { withAnimation(.spring(duration: 0.4)) { context.delete(t) } }
            }
        }
    }

    // MARK: Selecting several titles

    private var selectedList: [Title] { titles.filter { model.selectedTitles.contains($0.persistentModelID) } }

    private func selectAll(_ list: [Title]) {
        withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
            model.selecting = true
            model.selectedTitles = Set(list.map(\.persistentModelID))
        }
    }

    private func setStatus(_ status: WatchStatus) {
        withAnimation(.spring(duration: 0.4)) {
            for t in selectedList { t.status = status }
            model.selectedTitles = []
        }
    }

    private func setOpinion(_ opinion: Opinion) {
        withAnimation(.spring(duration: 0.3)) { for t in selectedList { t.opinion = opinion } }
    }

    private func removeSelected() {
        withAnimation(.spring(duration: 0.4)) {
            for t in selectedList { context.delete(t) }
            model.selectedTitles = []
            model.selecting = false
        }
    }

    @ToolbarContentBuilder
    private func selectionToolbar(_ list: [Title]) -> some ToolbarContent {
        let none = model.selectedTitles.isEmpty
        let allSelected = !list.isEmpty && list.allSatisfy { model.selectedTitles.contains($0.persistentModelID) }
        ToolbarItem {
            Button(allSelected ? "Deselect All" : "Select All") {
                if allSelected { withAnimation(.spring(duration: 0.3)) { model.selectedTitles = [] } } else { selectAll(list) }
            }
            .help(allSelected ? "Deselect all titles" : "Select every title shown (⌘A)")
        }
        ToolbarItem {
            Menu {
                ForEach(WatchStatus.allCases) { s in
                    Button { setStatus(s) } label: { Label("Mark as \(s.label)", systemImage: s.symbol) }
                }
            } label: {
                Label("Mark As", systemImage: "checkmark.circle").labelStyle(.titleAndIcon)
            }
            .disabled(none)
            .help("Move the selected titles to Up Next, Watching or Watched")
        }
        ToolbarItem {
            Menu {
                Button { setOpinion(.liked) } label: { Label("I Like This", systemImage: "hand.thumbsup") }
                Button { setOpinion(.disliked) } label: { Label("Not for Me", systemImage: "hand.thumbsdown") }
                Divider()
                Button { setOpinion(.none) } label: { Label("Clear Rating", systemImage: "hand.thumbsup.slash") }
            } label: {
                Label("Rate", systemImage: "hand.thumbsup").labelStyle(.titleAndIcon)
            }
            .disabled(none)
            .help("Thumbs up or down for the selected titles")
        }
        ToolbarItem {
            Button(role: .destructive) { confirmBulkRemove = true } label: {
                Label("Remove", systemImage: "trash").labelStyle(.titleAndIcon)
            }
            .disabled(none)
            .help("Remove the selected titles from your library (Delete)")
        }
        ToolbarItem {
            Button("Done") { model.toggleSelecting() }
                .buttonStyle(.borderedProminent)
                .help("Stop selecting (Esc)")
        }
    }

    /// Right-click menu for several selected titles.
    @ViewBuilder
    private var bulkMenu: some View {
        let n = model.selectedTitles.count
        ForEach(WatchStatus.allCases) { s in
            Button { setStatus(s) } label: { Label("Mark \(n) as \(s.label)", systemImage: s.symbol) }
        }
        Divider()
        Button { setOpinion(.liked) } label: { Label("I Like These", systemImage: "hand.thumbsup") }
        Button { setOpinion(.disliked) } label: { Label("Not for Me", systemImage: "hand.thumbsdown") }
        Button { setOpinion(.none) } label: { Label("Clear Rating", systemImage: "hand.thumbsup.slash") }
        Divider()
        Button("Remove \(n) Titles from Library…", role: .destructive) { confirmBulkRemove = true }
    }

    @ViewBuilder
    private func menu(for title: Title) -> some View {
        let platforms = title.watchPlatforms
        if !platforms.isEmpty {
            ForEach(platforms) { p in
                Button {
                    Task { await LinkResolver.shared.open(p, type: title.mediaType, id: title.tmdbID, name: title.name) }
                } label: { PlatformMenuLabel(platform: p, prefix: "Open in ") }
            }
            Divider()
        }
        ForEach(WatchStatus.allCases) { s in
            Button { withAnimation(.spring(duration: 0.4)) { title.status = s } } label: {
                Label("Mark as \(s.label)", systemImage: title.status == s ? "checkmark" : s.symbol)
            }
            .disabled(title.status == s)
        }
        if title.isTV, let total = title.seasons, total > 1 {
            Menu("Seasons Watched") {
                ForEach(0...total, id: \.self) { n in
                    Toggle(isOn: Binding(get: { title.seasonsWatched == n },
                                         set: { if $0 { withAnimation(.spring(duration: 0.4)) { title.markSeasons(n) } } })) {
                        Text(SeasonProgress.optionName(n, total: total))
                    }
                }
            }
        }
        Divider()
        Toggle(isOn: Binding(get: { title.opinion == .liked }, set: { title.opinion = $0 ? .liked : .none })) {
            Label("I Like This", systemImage: "hand.thumbsup")
        }
        Toggle(isOn: Binding(get: { title.opinion == .disliked }, set: { title.opinion = $0 ? .disliked : .none })) {
            Label("Not for Me", systemImage: "hand.thumbsdown")
        }
        Divider()
        Menu("Spotted On") {
            Button("None") { title.platform = nil }
            ForEach(Platform.allCases) { p in
                Toggle(isOn: Binding(get: { title.platform == p }, set: { if $0 { title.platform = p } })) {
                    PlatformMenuLabel(platform: p)
                }
            }
        }
        Divider()
        Button("Remove from Library…", role: .destructive) { pendingDelete = title }
    }
}

extension LibraryView {
    static func genreCounts(_ titles: [Title]) -> [Genre: Int] {
        var counts: [Genre: Int] = [:]
        for t in titles { for g in Genre.groups(names: t.genres) { counts[g, default: 0] += 1 } }
        return counts
    }
}

struct PosterCard: View {
    let title: Title
    /// nil when not selecting; otherwise whether this title is selected.
    var selected: Bool? = nil
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterImage(url: title.posterURL, title: title.name)
                .overlay(alignment: .topLeading) {
                    if let seasons = title.seasonsWatchedShort, title.partlyWatched {
                        Label("\(seasons) watched", systemImage: "checkmark.circle")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94), in: Capsule())
                            .padding(7)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else if title.status != .want {
                        Label(title.status.label, systemImage: title.status.symbol)
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            // Solid, not a material: this badge is content, not a floating control.
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94), in: Capsule())
                            .padding(7)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.primary.opacity(hovering ? 0.18 : 0.08), lineWidth: 1)
                }
                .overlay {
                    if selected == true {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(selected ? Color.white : Color.white, selected ? Color.accentColor : Color.black.opacity(0.25))
                            .background(Circle().fill(selected ? Color.accentColor : Color.black.opacity(0.25)).padding(2))
                            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                            .padding(8)
                            .contentTransition(.symbolEffect(.replace))
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                }
                // Fixed-radius shadow; only its opacity changes on hover.
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.14), radius: 8, y: 5)
                .scaleEffect(hovering && !reduceMotion ? 1.045 : 1)
                .offset(y: hovering && !reduceMotion ? -4 : 0)

            Text(title.name)
                .font(.headline)
                .lineLimit(1)
                .padding(.top, 10)
            metaWithOpinion
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 1)
            // Where it was spotted, or else where it's streaming (titles added from search have no screenshot).
            if let p = title.watchPlatforms.first {
                PlatformLabel(platform: p)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .contentShape(Rectangle())
        // Hover tracking is switched off while scrolling: posters sliding under a still pointer
        // otherwise make SwiftUI re-check every card's hover area on every frame.
        .modifier(HoverIf(on: !ScrollActivity.shared.isScrolling, hovering: $hovering))
        .animation(.spring(duration: 0.4, bounce: 0.3), value: title.status)
    }

    /// The meta line, with a small thumb when you've rated the title.
    private var metaWithOpinion: Text {
        switch title.opinion {
        case .none: Text(meta)
        case .liked: Text("\(meta)  \(Image(systemName: "hand.thumbsup.fill"))")
        case .disliked: Text("\(meta)  \(Image(systemName: "hand.thumbsdown.fill"))")
        }
    }

    private var meta: String {
        var parts = [title.isTV ? "Series" : "Movie"]
        if let y = title.year { parts.append(String(y)) }
        if let r = title.rating { parts.append("★ \(r.formatted(.number.precision(.fractionLength(1))))") }
        return parts.joined(separator: " · ")
    }
}

extension Title {
    /// Services to offer "Open in …" for: where it was spotted first, then where it's streaming.
    var watchPlatforms: [Platform] {
        var out: [Platform] = []
        if let p = platform { out.append(p) }
        for raw in streamingRaw { if let p = Platform.exact(raw), !out.contains(p) { out.append(p) } }
        return out
    }
}

/// The + button that opens the Add page. Shows how many screenshot titles are waiting for review.
struct AddButton: View {
    let pending: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Add Titles", systemImage: "plus")
        }
        .overlay(alignment: .topTrailing) {
            if pending > 0 {
                Text("\(pending)")
                    .font(.caption2.weight(.bold))   // 10 pt, the macOS minimum
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                    .background(Capsule().fill(.red))
                    .offset(x: 6, y: -5)
                    .contentTransition(.numericText())
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.4), value: pending)
        .help("Add titles from screenshots or search (⌘N)")
        .accessibilityLabel(pending > 0 ? "Add Titles, \(pending) waiting for review" : "Add Titles")
    }
}

extension Title {
    /// What VoiceOver reads for a poster.
    var accessibilityDescription: String {
        var parts = [name, isTV ? "Series" : "Movie"]
        if let year { parts.append(String(year)) }
        if let rating { parts.append("rated \(rating.formatted(.number.precision(.fractionLength(1)))) out of 10") }
        if let progress = seasonProgressText, let short = seasonsWatchedShort { parts.append("watched \(short), \(progress)") }
        else if status != .want { parts.append(status.label) }
        if opinion == .liked { parts.append("you like this") } else if opinion == .disliked { parts.append("not for you") }
        if let p = watchPlatforms.first { parts.append("on \(p.rawValue)") }
        return parts.joined(separator: ", ")
    }
}

/// Adds the hover lift only when `on`; when it switches off (scrolling starts) the card settles back.
struct HoverIf: ViewModifier {
    let on: Bool
    @Binding var hovering: Bool
    func body(content: Content) -> some View {
        Group {
            if on { content.onHover { h in withAnimation(.spring(duration: 0.35, bounce: 0.35)) { hovering = h } } } else { content }
        }
        .onChange(of: on) { _, now in if !now && hovering { hovering = false } }
    }
}

/// Whether a grid is being scrolled right now (from the scroll view's own phase).
@MainActor @Observable
final class ScrollActivity {
    static let shared = ScrollActivity()
    var isScrolling = false
}
