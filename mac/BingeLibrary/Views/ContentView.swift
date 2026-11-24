import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \Title.addedAt, order: .reverse) private var titles: [Title]
    @AppStorage("appearance") private var appearance: AppearanceMode = .system
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        let covered = model.addPresented || model.detail != nil
        NavigationSplitView {
            Sidebar(titles: titles)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            ZStack {
                Group {
                    if !model.hasTMDB {
                        SetupView()
                    } else if model.selection == .forYou {
                        ForYouView(titles: titles)
                    } else if model.selection == .updates {
                        UpdatesView(titles: titles)
                    } else if model.selection == .review {
                        YearInReviewView(titles: titles)
                    } else {
                        LibraryView(filter: model.selection ?? .status(.want), titles: titles)
                    }
                }
                // Push the library back while a page is on top of it, for depth.
                .scaleEffect(covered && !reduceMotion ? 0.94 : 1)
                .opacity(covered ? 0 : 1)
                .allowsHitTesting(!covered)

                if model.addPresented {
                    AddView()
                        .scaleEffect(model.detail == nil || reduceMotion ? 1 : 0.94)
                        .opacity(model.detail == nil ? 1 : 0)
                        .allowsHitTesting(model.detail == nil)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .topTrailing).combined(with: .opacity))
                        .zIndex(1)
                }

                if let item = model.detail {
                    DetailPage(item: item, titles: titles)
                        // Zooms from the poster you clicked; a plain fade with Reduce Motion.
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .scale(scale: 0.35, anchor: model.detailAnchor).combined(with: .opacity),
                            removal: .scale(scale: 0.35, anchor: model.detailAnchor).combined(with: .opacity)))
                        .zIndex(2)
                }
            }
            .coordinateSpace(.named("detailArea"))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DetailArea.frame = $0; DetailArea.size = $0.size }
            .overlay { if dropTargeted { DropOverlay().transition(.opacity.combined(with: .scale(scale: 1.02))) } }
            .animation(.spring(duration: 0.3, bounce: 0.2), value: dropTargeted)
            // One search field: filters the library, or finds new titles on the Add page.
            .searchable(text: model.addPresented ? $model.titleSearch : $model.librarySearch,
                        placement: .toolbar,
                        prompt: model.addPresented ? "Search Movies and TV Shows" : "Search Library")
            .searchFocused($searchFocused)
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            Task { model.enqueue(await ImageUtils.loadImages(from: providers)) }
            return true
        }
        .onChange(of: model.selection) {
            if model.selecting { model.toggleSelecting() }
            if model.detail != nil { model.closeDetail() }
            if model.addPresented { model.closeAdd() }
        }
        .onChange(of: appearance, initial: true) { appearance.apply() }
        .onChange(of: model.focusSearchRequest) { searchFocused = true }
        .onChange(of: model.librarySearch) { _, text in
            // Searching from For You searches the whole library.
            if model.selection == .forYou && !text.isEmpty { model.selection = .all }
        }
        .onChange(of: titles.map(\.tmdbID), initial: true) {
            model.libraryKeys = Set(titles.map { "\($0.mediaType):\($0.tmdbID)" })
        }
        // Edit ▸ Undo (⌘Z) for adding, removing and changing titles, through the window's undo manager.
        .onChange(of: undoManager, initial: true) { context.undoManager = undoManager }
        .task {
            // Agents (MCP) edit the same data as this window, so changes show up here at once.
            MCPServer.shared.attach(model: model, context: context)
            AlertCenter.shared.attach(model: model, context: context)
            LegacyImport.runIfNeeded(model: model, context: context)
            ScrollBenchmark.runIfRequested()
            // Recompute stored platforms once after matching rules change (v2: exact provider names).
            // Shows marked Watched before season tracking existed: count every season they had then.
            if UserDefaults.standard.integer(forKey: "seasonsVersion") < 1 {
                for t in titles where t.isTV && t.status == .watched && t.seasonsWatched == 0 { t.seasonsWatched = t.seasons ?? 0 }
                UserDefaults.standard.set(1, forKey: "seasonsVersion")
            }
            if UserDefaults.standard.integer(forKey: "platformsVersion") < 2 {
                for t in titles where t.providersData != nil { t.providers = t.providers }
                UserDefaults.standard.set(2, forKey: "platformsVersion")
            }
            #if DEBUG
            if let s = UserDefaults.standard.string(forKey: "BLOpenDetail"), let i = Int(s), titles.indices.contains(i) {
                try? await Task.sleep(for: .seconds(1))
                model.openDetail(.title(titles[i].persistentModelID))
            }
            if UserDefaults.standard.string(forKey: "BLSelect") == "forYou" { model.selection = .forYou }
            if UserDefaults.standard.string(forKey: "BLSelect") == "review" { model.selection = .review }
            if UserDefaults.standard.string(forKey: "BLSelect") == "updates" { model.selection = .updates }
            if let name = UserDefaults.standard.string(forKey: "BLOpenTitle"), let t = titles.first(where: { $0.name == name }) {
                try? await Task.sleep(for: .seconds(1))
                model.openDetail(.title(t.persistentModelID))
            }
            StallTest.runIfRequested(model: model, context: context)
            if UserDefaults.standard.bool(forKey: "BLOpenSettings") {
                try? await Task.sleep(for: .seconds(1))
                openSettings()
            }
            if UserDefaults.standard.bool(forKey: "BLOpenAdd") {
                try? await Task.sleep(for: .seconds(1))
                model.openAdd()
            }
            #endif
        }
    }
}

/// Size of the content area, used to turn a click location into a zoom anchor.
enum DetailArea {
    @MainActor static var size: CGSize = CGSize(width: 1, height: 1)
    /// Content area's frame in window coordinates (top-left origin).
    @MainActor static var frame: CGRect = .zero

    @MainActor static func anchor(for point: CGPoint) -> UnitPoint {
        UnitPoint(x: point.x / max(size.width, 1), y: point.y / max(size.height, 1))
    }

    /// Where the current mouse click happened, as a zoom anchor. Keyboard activation opens from the center.
    @MainActor static func anchorForCurrentClick() -> UnitPoint {
        guard let event = NSApp.currentEvent,
              [.leftMouseUp, .leftMouseDown].contains(event.type),
              let content = event.window?.contentView, frame.width > 0 else { return .center }
        let p = event.locationInWindow   // bottom-left origin
        let point = CGPoint(x: p.x - frame.minX, y: (content.bounds.height - p.y) - frame.minY)
        return UnitPoint(x: min(max(point.x / frame.width, 0), 1), y: min(max(point.y / frame.height, 0), 1))
    }
}

struct DropOverlay: View {
    @State private var pulse = false
    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.accentColor.opacity(0.08)))
            .overlay {
                Label("Drop screenshots to add them", systemImage: "photo.on.rectangle.angled")
                    .font(.title2.weight(.semibold))
                    .symbolEffect(.bounce, options: .repeating.speed(0.6), value: pulse)
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(14)
            .allowsHitTesting(false)
            .onAppear { pulse = true }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    let titles: [Title]

    private var platforms: [Platform] {
        let present = Set(titles.flatMap(\.allPlatforms))
        return Platform.allCases.filter(present.contains)
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Label("For You", systemImage: "sparkles")
                .tag(SidebarItem.forYou)
            Label("Updates", systemImage: "bell")
                .badge(UpdatesStore.shared.unreadCount)
                .tag(SidebarItem.updates)
            Label("Year in Review", systemImage: "calendar.badge.checkmark")
                .tag(SidebarItem.review)

            Section("Library") {
                ForEach(WatchStatus.allCases) { s in
                    Label(s.label, systemImage: s.symbol)
                        .badge(titles.filter { $0.isIn(s) }.count)
                        .tag(SidebarItem.status(s))
                }
                Label("All Titles", systemImage: "square.grid.2x2")
                    .badge(titles.count)
                    .tag(SidebarItem.all)
            }

            if !platforms.isEmpty {
                Section("Platforms") {
                    ForEach(platforms) { p in
                        Label { Text(p.rawValue) } icon: { PlatformLogo(platform: p, size: 18) }
                            .badge(titles.filter { $0.allPlatforms.contains(p) }.count)
                            .tag(SidebarItem.platform(p))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct SetupView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Binge Library", systemImage: "play.rectangle.on.rectangle")
        } description: {
            Text("Add your free TMDB key in Settings to get posters, summaries and where to watch.")
        } actions: {
            SettingsLink { Text("Open Settings…") }
                .buttonStyle(.borderedProminent)
        }
    }
}
