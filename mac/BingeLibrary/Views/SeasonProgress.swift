import SwiftUI

/// "Your progress": which seasons of a show you've watched. Click a season to mark it and every
/// season before it as watched; click the last watched season again to unmark it.
/// Partly watched shows sit in both Watched and Up Next.
struct SeasonProgress: View {
    @Bindable var title: Title

    var body: some View {
        if let total = title.seasons, total >= 1 {
            HStack(spacing: 14) {
                Text("Seasons Watched")
                    .font(.headline)
                if total <= 12 {
                    HStack(spacing: 6) {
                        ForEach(1...total, id: \.self) { n in chip(n) }
                    }
                } else {
                    Picker("Seasons Watched", selection: Binding(get: { title.seasonsWatched },
                                                                 set: { n in withAnimation(AppModel.motion) { title.markSeasons(n) } })) {
                        ForEach(0...total, id: \.self) { n in Text(Self.optionName(n, total: total)).tag(n) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text(summary(total))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .animation(AppModel.motion, value: title.seasonsWatched)
        }
    }

    private func chip(_ n: Int) -> some View {
        let watched = n <= title.seasonsWatched
        return Button {
            // Clicking the last watched season again steps back one; otherwise watch up to this one.
            withAnimation(AppModel.motion) { title.markSeasons(n == title.seasonsWatched ? n - 1 : n) }
        } label: {
            HStack(spacing: 4) {
                if watched { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                Text("S\(n)")
            }
            .frame(minWidth: 30)
        }
        .buttonStyle(.bordered)
        .tint(watched ? .accentColor : nil)
        .controlSize(.large)
        .help(watched && n == title.seasonsWatched ? "Mark Season \(n) as not watched"
              : "Mark Season\(n == 1 ? "" : "s") 1\(n == 1 ? "" : "–\(n)") as watched")
        .accessibilityLabel("Season \(n)")
        .accessibilityValue(watched ? "Watched" : "Not watched")
    }

    private func summary(_ total: Int) -> String {
        if let progress = title.seasonProgressText { return progress + ". It’s in Watched and Up Next." }
        if title.seasonsWatched >= total && title.seasonsWatched > 0 { return "All caught up." }
        return total == 1 ? "Not watched yet." : "Click the last season you finished."
    }

    /// Menu wording: "None", "Season 1", "Seasons 1–3", "All 5 Seasons".
    static func optionName(_ n: Int, total: Int) -> String {
        if n == 0 { return "None" }
        if n == total && total > 1 { return "All \(total) Seasons" }
        return n == 1 ? "Season 1" : "Seasons 1–\(n)"
    }
}
