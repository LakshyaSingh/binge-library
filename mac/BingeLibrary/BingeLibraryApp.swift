import SwiftUI
import SwiftData

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var themeObserver: NSObjectProtocol?
    /// Opened by "Open at login": start hidden so the daily alert check runs without a window popping up.
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAtLogin = true
        }
    }

    /// Launching the app always shows the library, even if the window was closed when it last quit.
    func applicationDidFinishLaunching(_ notification: Notification) {
        refreshDockIcon()
        // Light/dark mode (and icon style) changes: redraw the Dock icon to match.
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refreshDockIcon() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                AppModel.shared.openMainWindow?()
            }
            if self.launchedAtLogin { NSApp.hide(nil) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { refreshDockIcon() }

    /// Gives the Dock the icon exactly as macOS draws it in Finder and the app launcher.
    ///
    /// Left to itself, a running app's Dock icon could come out in the dark variant while the
    /// system was in light mode. The system icon service always renders the variant that matches
    /// the current appearance and icon style (Default, Dark, Clear or Tinted).
    private func refreshDockIcon() {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = NSSize(width: 512, height: 512)
        NSApp.applicationIconImage = icon
    }

    /// Screenshots dropped on the Dock icon, or opened with "Open With → Binge Library".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppModel.shared.enqueue(urls: urls)
            // When launched by a Dock drop (or after the window was closed) there may be no window yet.
            try? await Task.sleep(for: .milliseconds(150))
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                AppModel.shared.openMainWindow?()
            }
            NSApp.activate()
        }
    }
}

/// Grabs SwiftUI's openWindow action at launch (commands exist even when no window is open).
struct WindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        let _ = MainActor.assumeIsolated {
            AppModel.shared.openMainWindow = { openWindow(id: "main") }
            AppModel.shared.openTrailerWindow = { openWindow(id: "trailer") }
        }
        CommandGroup(after: .windowList) {}
    }
}

/// The library's database: a file of its own, ~/Library/Application Support/Binge Library/Library.store.
///
/// It used to be SwiftData's unnamed default, ~/Library/Application Support/default.store, which any other
/// app using SwiftData's defaults also opens. On Nov 12, 2026 another app opened it, converted it to its own
/// format and the titles were lost (recovered from the file afterwards). A private file can't be touched that way.
enum LibraryStore {
    static var url: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Binge Library", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "Library.store")
    }

    static let container: ModelContainer = {
        let config = ModelConfiguration("Library", schema: Schema([Title.self]), url: url)
        do {
            return try ModelContainer(for: Title.self, configurations: config)
        } catch {
            fatalError("Couldn’t open the library at \(url.path): \(error)")
        }
    }()
}

@main
struct BingeLibraryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @AppStorage("appearance") private var appearance: AppearanceMode = .system
    @AppStorage("libraryType") private var typeFilter: TypeFilter = .all
    @AppStorage("librarySort") private var sort: LibrarySort = .added
    @AppStorage("libraryGenre") private var libraryGenre = ""
    @AppStorage("forYouGenre") private var forYouGenre = ""

    /// The genre filter for whichever page is showing (For You keeps its own).
    private var genreBinding: Binding<String> {
        model.selection == .forYou ? $forYouGenre : $libraryGenre
    }

    init() {
        // Generous cache so posters load instantly after the first time.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        Window("Binge Library", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 540)
        }
        // Undo/Redo (⌘Z / ⇧⌘Z) for adding, removing and changing titles.
        .modelContainer(LibraryStore.container)
        .defaultSize(width: 1180, height: 760)
        .commands {
            WindowCommands()
            CommandGroup(after: .pasteboard) {
                Divider()
                Button(model.selecting ? "Done Selecting" : "Select Titles") { model.toggleSelecting() }
                    .disabled(model.selection == .forYou || model.selection == .review || model.selection == .updates || model.detail != nil || model.addPresented)
            }
            CommandGroup(after: .textEditing) {
                Button("Search") { model.focusSearchRequest += 1 }
                    .keyboardShortcut("f")
            }
            CommandGroup(after: .newItem) {
                Button("Add Screenshots…") {
                    model.openAdd()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(name: .chooseScreenshots, object: nil)
                    }
                }
                .keyboardShortcut("o")
                Button("Add Titles") { model.openAdd() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .sidebar) {
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[")
                    .disabled(!model.canGoBack)
                Divider()
                Button("For You") { model.selection = .forYou }.keyboardShortcut("0")
                Button("Updates") { model.selection = .updates }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Year in Review") { model.selection = .review }
                Button("Up Next") { model.selection = .status(.want) }.keyboardShortcut("1")
                Button("Watching") { model.selection = .status(.watching) }.keyboardShortcut("2")
                Button("Watched") { model.selection = .status(.watched) }.keyboardShortcut("3")
                Button("All Titles") { model.selection = .all }.keyboardShortcut("4")
                Divider()
                Picker("Show", selection: $typeFilter) {
                    ForEach(TypeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Genre", selection: genreBinding) {
                    Text("All Genres").tag("")
                    Divider()
                    ForEach(Genre.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker("Sort By", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("Refresh Recommendations") {
                    model.selection = .forYou
                    model.refreshRecommendationsRequest += 1
                }
                .keyboardShortcut("r")
                Divider()
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                Divider()
            }
        }

        Window("Trailer", id: "trailer") {
            TheaterView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(model)
                .modelContainer(LibraryStore.container)
        }
    }
}

extension Notification.Name {
    static let chooseScreenshots = Notification.Name("chooseScreenshots")
}
