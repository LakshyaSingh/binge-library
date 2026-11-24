import SwiftUI
import SwiftData

/// The Settings window: one short tab per topic, so every pane fits on any screen.
struct SettingsView: View {
    /// Reopens on the tab you used last.
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            ServicesPane()
                .tabItem { Label("Services", systemImage: "key") }
                .tag("services")
            Form { AlertsSection() }
                .formStyle(.grouped)
                .settingsPaneSize()
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
                .tag("alerts")
            Form { AgentsSection() }
                .formStyle(.grouped)
                .settingsPaneSize()
                .tabItem { Label("AI Agents", systemImage: "sparkles") }
                .tag("agents")
        }
    }
}

private extension View {
    func settingsPaneSize() -> some View {
        frame(width: 520).fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @AppStorage("appearance") private var appearance: AppearanceMode = .system
    @AppStorage("autoplayTrailers") private var autoplayTrailers = true
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Automatic follows your Mac’s appearance in System Settings, which is usually the best choice.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play trailers automatically", isOn: $autoplayTrailers)
                Text("When you open a movie or show, its trailer starts playing (muted) after a moment.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Earlier web version") {
                    Button("Import Library…") {
                        let n = LegacyImport.run(from: LegacyImport.defaultFolder, model: model, context: context)
                        status = n == 0 ? "Nothing new to import." : "Imported \(n) title\(n == 1 ? "" : "s")."
                    }
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Import") }
        }
        .formStyle(.grouped)
        .settingsPaneSize()
    }
}

private struct ServicesPane: View {
    @Environment(AppModel.self) private var model
    @State private var tmdb = ""
    @State private var gemini = ""
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                keyField("TMDB", connected: model.hasTMDB, text: $tmdb, prompt: "API key or read access token")
                Text("Required. Posters, summaries and where to watch. Get a free key at [themoviedb.org](https://www.themoviedb.org/settings/api).")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Movie Database") }

            Section {
                keyField("Gemini", connected: model.hasGemini, text: $gemini, prompt: "API key (optional)")
                Text("Optional. Reads screenshots most accurately, including stylized title logos. Without it, Binge Library uses Apple’s on-device text recognition. Get a free key at [aistudio.google.com](https://aistudio.google.com/apikey).")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Screenshot Recognition") }

            Section {
                HStack {
                    Button("Save Keys") {
                        model.saveKeys(tmdb: tmdb.isEmpty ? nil : tmdb, gemini: gemini.isEmpty ? nil : gemini)
                        tmdb = ""; gemini = ""
                        status = "Saved to your Keychain."
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(tmdb.isEmpty && gemini.isEmpty)
                    if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                }
                Text("Keys are stored in your Mac’s Keychain. This product uses the TMDB API but is not endorsed or certified by TMDB. Streaming availability from JustWatch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .settingsPaneSize()
    }

    private func keyField(_ label: String, connected: Bool, text: Binding<String>, prompt: String) -> some View {
        LabeledContent {
            SecureField(label, text: text, prompt: Text(connected ? "Saved. Paste a new key to replace it" : prompt))
                .labelsHidden()
                .frame(minWidth: 260)
        } label: {
            HStack(spacing: 6) {
                Text(label)
                if connected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Connected") }
            }
        }
    }
}

/// Settings ▸ AI Agents: the local MCP server for agents on this Mac.
private struct AgentsSection: View {
    @State private var server = MCPServer.shared
    @State private var copied: String?
    @State private var confirmNewKey = false

    var body: some View {
        Section {
            Toggle("Let AI agents use your library", isOn: $server.enabled)
            Text("Agents on this Mac that support MCP (the Model Context Protocol), such as Claude or your own bots, can search your library, add titles, change their status or thumbs, remove them, and get recommendations. Only apps on this Mac that have the key can connect.")
                .font(.caption).foregroundStyle(.secondary)

            if server.enabled {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Address") {
                    Text(server.url).font(.callout.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Key") {
                    HStack(spacing: 8) {
                        Text(String(server.token.prefix(7)) + "•••••••").font(.callout.monospaced()).foregroundStyle(.secondary)
                        Button("Copy") { copy(server.token, "Key copied.") }
                        Button("New Key…") { confirmNewKey = true }
                    }
                }
                LabeledContent("Set up your agent") {
                    HStack(spacing: 8) {
                        Button("Copy HTTP Setup") { copy(server.httpSetup, "HTTP setup copied. Paste it into your agent’s MCP settings.") }
                            .help("For agents that connect to an address (most MCP clients)")
                        Button("Copy Command Setup") { copy(server.commandSetup, "Command setup copied. Paste it into your agent’s MCP settings.") }
                            .help("For agents that start MCP servers as programs (stdio). No key needed in the settings.")
                    }
                }
                if let copied {
                    Text(copied).font(.caption).foregroundStyle(.secondary)
                } else if let client = server.lastClient, let when = server.lastActivity {
                    Text("Last used by \(client) \(when.formatted(.relative(presentation: .named))).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: { Text("AI Agents") }
        .confirmationDialog("Create a new key?", isPresented: $confirmNewKey) {
            Button("Create New Key") { server.regenerateToken(); copied = "New key created. Agents using the old key need the new one." }
        } message: {
            Text("Agents set up with the current key will stop working until you give them the new one.")
        }
    }

    private var statusText: String {
        switch server.status {
        case .off: "Off"
        case .starting: "Starting…"
        case .running: "Running, only on this Mac"
        case .failed(let message): "Couldn’t start: \(message)"
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .running: .green
        case .failed: .orange
        default: .secondary
        }
    }

    private func copy(_ text: String, _ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = message }
    }
}

/// Settings ▸ Alerts: notifications about titles in the library.
private struct AlertsSection: View {
    @State private var alerts = AlertCenter.shared

    var body: some View {
        Section {
            Toggle("Notify me about titles in my library", isOn: $alerts.enabled)
            Text("Once a day, Binge Library checks your titles on TMDB and sends a notification when something you care about changes. Clicking a notification opens that title.")
                .font(.caption).foregroundStyle(.secondary)
            if alerts.enabled {
                Toggle("New seasons", isOn: $alerts.seasonAlerts)
                Text("When a show in your library gets a new season, a week before it starts, and on the day it’s out. Includes shows you’ve watched.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Newly streaming", isOn: $alerts.streamingAlerts)
                Text("When something in Up Next or Watching arrives on Netflix, Prime Video, Apple TV, Hulu, HBO Max, Disney+, Peacock or Paramount+, including movies that were rent or buy only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        if alerts.enabled {
            Section {
                if alerts.permission == .denied {
                    LabeledContent("Notifications are off") {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                    Text("Binge Library isn’t allowed to show notifications. Turn them on in System Settings ▸ Notifications ▸ Binge Library.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Open Binge Library at login", isOn: Binding(get: { alerts.openAtLogin }, set: { alerts.openAtLogin = $0 }))
                Text(alerts.loginItemStatus == .requiresApproval
                     ? "Approve Binge Library in System Settings ▸ General ▸ Login Items to finish."
                     : "Checks only run while Binge Library is open. With this on, it opens hidden when you log in, so checks keep running.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Last check") {
                    HStack(spacing: 10) {
                        if alerts.checking {
                            ProgressView(value: alerts.progress).frame(width: 90)
                            Text("Checking…").foregroundStyle(.secondary)
                        } else {
                            Text(alerts.lastCheck.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet")
                                .foregroundStyle(.secondary)
                            Button("Check Now") { Task { await alerts.check() } }
                        }
                    }
                }
                if let result = alerts.lastResult, !alerts.checking {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
