import SwiftUI

/// Toolbar menu that filters by genre. Lists only genres present in what's on screen, with counts.
struct GenreFilterMenu: View {
    /// Genre.rawValue, or "" for all genres.
    @Binding var selection: String
    let counts: [Genre: Int]

    private var current: Genre? { Genre(rawValue: selection) }

    var body: some View {
        Menu {
            Picker("Genre", selection: $selection.animation(.spring(duration: 0.45, bounce: 0.15))) {
                Text("All Genres").tag("")
                Divider()
                ForEach(Genre.allCases.filter { (counts[$0] ?? 0) > 0 || $0 == current }) { g in
                    Label("\(g.rawValue) (\(counts[g] ?? 0))", systemImage: g.symbol).tag(g.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(current?.rawValue ?? "Genre",
                  systemImage: current == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .labelStyle(.titleAndIcon)
        }
        .help(current.map { "Showing \($0.rawValue) only. Click to change genre." } ?? "Filter by genre")
        .accessibilityLabel(current.map { "Genre filter, \($0.rawValue)" } ?? "Genre filter, all genres")
    }
}

/// Shown when a genre filter leaves nothing to show.
struct GenreEmptyView: View {
    let genre: Genre
    let clear: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No \(genre.rawValue) Titles Here", systemImage: genre.symbol)
        } description: {
            Text("Nothing in this list matches \(genre.rawValue).")
        } actions: {
            Button("Show All Genres", action: clear)
        }
    }
}
