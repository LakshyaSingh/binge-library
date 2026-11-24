import SwiftUI

/// Every alert in one place: newly streaming with your subscriptions, new seasons, premieres.
/// Notifications can be dismissed; these stay until you remove them.
struct UpdatesView: View {
    let titles: [Title]
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"
    @State private var confirmClear = false
    private var store: UpdatesStore { .shared }
    private var alerts: AlertCenter { .shared }
    private var covered: Bool { model.detail != nil || model.addPresented }

    var body: some View {
        Group {
            if store.items.isEmpty {
                empty
            } else {
                list
            }
        }
        .navigationTitle(covered ? "" : "Updates")
        .navigationSubtitle(covered || store.items.isEmpty ? "" : subtitle)
        .toolbar {
            if !covered {
                if alerts.enabled {
                    ToolbarItem {
                        Button {
                            Task { await alerts.check() }
                        } label: {
                            Label("Check Now", systemImage: "arrow.clockwise")
                        }
                        .disabled(alerts.checking)
                        .help("Look for new seasons and streaming changes now")
                    }
                }
                ToolbarItem {
                    Button {
                        withAnimation(AppModel.motion) { store.markAllRead() }
                    } label: {
                        Label("Mark All as Read", systemImage: "checkmark.circle")
                    }
                    .disabled(store.unreadCount == 0)
                    .help("Mark all updates as read")
                }
                ToolbarItem {
                    Menu {
                        Button("Clear All Updates…", role: .destructive) { confirmClear = true }
                            .disabled(store.items.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden)
                    .help("More")
                }
            }
        }
        .confirmationDialog("Clear all updates?", isPresented: $confirmClear) {
            Button("Clear All Updates", role: .destructive) { withAnimation(AppModel.motion) { store.clear() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every update from this page. Your library isn’t changed.")
        }
        // Leaving the page counts as having seen what was on it.
        .onDisappear { store.markAllRead() }
    }

    private var subtitle: String {
        store.unreadCount > 0 ? "\(store.unreadCount) unread" : "\(store.items.count) update\(store.items.count == 1 ? "" : "s")"
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                if alerts.checking {
                    HStack(spacing: 10) {
                        ProgressView(value: alerts.progress).frame(maxWidth: 220)
                        Text("Checking your library…").foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 18)
                }
                ForEach(sections, id: \.name) { section in
                    Text(section.name)
                        .font(.title3.weight(.semibold))
                        .padding(.top, section.name == sections.first?.name ? 0 : 26)
                        .padding(.bottom, 8)
                    VStack(spacing: 0) {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { i, item in
                            if i > 0 { Divider().padding(.leading, 86) }
                            UpdateRow(item: item, title: libraryTitle(item)) { open(item) }
                        }
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                }
                Text("Updates stay here after you dismiss a notification. Streaming data from JustWatch via TMDB.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 22)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private struct Section { var name: String; var items: [UpdatesStore.Item] }

    private var sections: [Section] {
        let cal = Calendar.current
        let weekAgo = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date())) ?? .distantPast
        var groups: [(String, [UpdatesStore.Item])] = [("Today", []), ("Yesterday", []), ("This Week", []), ("Earlier", [])]
        for item in store.items {
            let i = cal.isDateInToday(item.date) ? 0 : cal.isDateInYesterday(item.date) ? 1 : item.date >= weekAgo ? 2 : 3
            groups[i].1.append(item)
        }
        return groups.filter { !$0.1.isEmpty }.map { Section(name: $0.0, items: $0.1) }
    }

    private func libraryTitle(_ item: UpdatesStore.Item) -> Title? {
        titles.first { "\($0.mediaType):\($0.tmdbID)" == item.titleID }
    }

    private func open(_ item: UpdatesStore.Item) {
        store.setRead(item.id)
        if let t = libraryTitle(item) { model.openDetail(.title(t.persistentModelID), from: DetailArea.anchorForCurrentClick()) }
    }

    // MARK: Empty

    private var empty: some View {
        ContentUnavailableView {
            Label("No Updates Yet", systemImage: "bell")
        } description: {
            Text(alerts.enabled
                 ? "When something on your list starts streaming with a subscription, or a show you follow gets a new season, it shows up here, even if you dismiss the notification."
                 : "Turn on alerts to hear when something on your list starts streaming with a subscription or a show gets a new season. Every alert is kept here.")
        } actions: {
            if alerts.enabled {
                Button(alerts.checking ? "Checking…" : "Check Now") { Task { await alerts.check() } }
                    .disabled(alerts.checking)
            } else {
                Button("Turn On Alerts…") { settingsTab = "alerts"; openSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct UpdateRow: View {
    let item: UpdatesStore.Item
    let title: Title?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                PosterImage(url: (item.poster ?? title?.posterURL)?.tmdbSize("w185"), title: title?.name ?? "", cornerRadius: 6, maxPixel: 160)
                    .frame(width: 48)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: item.kind.symbol)
                            .foregroundStyle(.tint)
                            .font(.callout)
                        Text(item.headline)
                            .font(.headline)
                            .lineLimit(2)
                    }
                    Text(item.body)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let progress = title?.seasonProgressText, item.kind != .streaming {
                        Text("You’ve watched \(title?.seasonsWatchedShort ?? ""). \(progress).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(item.date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 9, height: 9)
                        .opacity(item.read ? 0 : 1)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(title == nil && item.read)
        .help(title == nil ? "This title is no longer in your library" : "Open \(title!.name)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.read ? "" : "Unread")
        .contextMenu {
            Button(item.read ? "Mark as Unread" : "Mark as Read") { UpdatesStore.shared.setRead(item.id, !item.read) }
            if title != nil { Button("Show Title") { action() } }
            Divider()
            Button("Remove Update", role: .destructive) { withAnimation(AppModel.motion) { UpdatesStore.shared.remove(item.id) } }
        }
    }
}
