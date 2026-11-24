import SwiftUI
import SwiftData

/// Recommendations based on everything in the library.
struct ForYouView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let titles: [Title]
    @State private var recommender = Recommender.shared
    @AppStorage("forYouType") private var type: TypeFilter = .all
    @AppStorage("forYouGenre") private var genre: String = ""

    private var activeGenre: Genre? { Genre(rawValue: genre) }

    private var covered: Bool { model.detail != nil || model.addPresented }

    /// Not already in the library, and matching the type filter (before the genre filter).
    private func available(_ list: [Recommendation]) -> [Recommendation] {
        list.filter { r in
            !model.libraryKeys.contains(r.id) && (type == .all || (type == .tv) == r.result.isTV)
        }
    }

    private func visible(_ list: [Recommendation]) -> [Recommendation] {
        available(list).filter { r in activeGenre.map { $0.matches(ids: r.result.genreIDs ?? []) } ?? true }
    }

    /// Genre counts across every recommendation on the page (each title counted once).
    private var genreCounts: [Genre: Int] {
        var seen = Set<String>(), counts: [Genre: Int] = [:]
        for r in available(recommender.picks.prefix(18) + recommender.rows.flatMap(\.items)) where seen.insert(r.id).inserted {
            for g in Genre.groups(ids: r.result.genreIDs ?? []) { counts[g, default: 0] += 1 }
        }
        return counts
    }

    var body: some View {
        let picks = visible(recommender.picks)
        let library = Dictionary(titles.map { ("\($0.mediaType):\($0.tmdbID)", $0) }, uniquingKeysWith: { a, _ in a })
        let nothingInGenre = activeGenre != nil && picks.isEmpty && recommender.rows.allSatisfy { visible($0.items).count < 3 }
        Group {
            if titles.isEmpty {
                ContentUnavailableView {
                    Label("Recommendations need a few titles", systemImage: "sparkles")
                } description: {
                    Text("Add some shows and movies you like, and For You will suggest more like them.")
                } actions: {
                    Button("Add Titles") { model.openAdd() }.buttonStyle(.borderedProminent)
                }
            } else if picks.isEmpty && recommender.isLoading {
                VStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse, options: .repeating)
                    Text("Finding shows you’ll like…").font(.title3.weight(.semibold))
                    ProgressView(value: recommender.progress).frame(width: 220)
                    Text("Looking at all \(titles.count) titles in your library").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let g = activeGenre, nothingInGenre, !recommender.isLoading {
                GenreEmptyView(genre: g) { withAnimation(.spring(duration: 0.45, bounce: 0.15)) { genre = "" } }
            } else if let error = recommender.lastError, picks.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t Load Recommendations", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await recommender.refresh(library: titles, tmdb: model.tmdb, force: true) } }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        if !picks.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                SectionHeader(title: "Top Picks for You",
                                              subtitle: "Recommended most often across your library")
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 22, alignment: .top)],
                                          alignment: .leading, spacing: 30) {
                                    ForEach(picks.prefix(18)) { r in
                                        RecommendationCard(rec: r, recommender: recommender, library: library)
                                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                                    }
                                }
                                .animation(.spring(duration: 0.45, bounce: 0.15), value: picks.prefix(18).map(\.id))
                            }
                        }
                        ForEach(recommender.rows) { row in
                            let items = visible(row.items)
                            if items.count >= 3 {
                                VStack(alignment: .leading, spacing: 14) {
                                    SectionHeader(title: row.heading, subtitle: nil)
                                    ScrollView(.horizontal) {
                                        LazyHStack(alignment: .top, spacing: 18) {
                                            ForEach(items) { r in
                                                RecommendationCard(rec: r, recommender: recommender, library: library, showReason: false)
                                                    .frame(width: 150)
                                                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                                            }
                                        }
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 24)
                                        .animation(.spring(duration: 0.45, bounce: 0.15), value: items.map(\.id))
                                    }
                                    .scrollIndicators(.never)
                                    .padding(.horizontal, -24)
                                }
                            }
                        }
                        Text("Recommendations from TMDB, based on everything in your library.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle(covered ? "" : "For You")
        .navigationSubtitle(covered || titles.isEmpty ? "" : "Based on your \(titles.count) titles")
        .toolbar {
            if !covered {
                ToolbarItem {
                    AddButton(pending: model.pendingReviewCount) { model.openAdd() }
                }
                ToolbarItem {
                    Picker("Type", selection: $type.animation(.spring(duration: 0.4, bounce: 0.15))) {
                        ForEach(TypeFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem {
                    GenreFilterMenu(selection: $genre, counts: genreCounts)
                }
                ToolbarItem {
                    Button {
                        Task { await recommender.refresh(library: titles, tmdb: model.tmdb, force: true) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .symbolEffect(.rotate, value: recommender.isLoading)
                    }
                    .disabled(recommender.isLoading)
                    .help("Refresh recommendations")
                }
            }
        }
        // Rebuild when titles are added or removed, or a status or thumbs changes.
        .task(id: titles.map { "\($0.tmdbID)\($0.statusRaw)\($0.opinionRaw)" }.joined(separator: ",")) {
            await recommender.refresh(library: titles, tmdb: model.tmdb)
        }
        .onChange(of: model.refreshRecommendationsRequest) {
            Task { await recommender.refresh(library: titles, tmdb: model.tmdb, force: true) }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.bold()).tracking(-0.3)
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

private struct RecommendationCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let rec: Recommendation
    let recommender: Recommender
    /// Library titles by "type:id", to list what led to this pick.
    let library: [String: Title]
    var showReason = true
    @State private var hovering = false
    @State private var adding = false
    @State private var showSources = false

    private var reason: String? {
        guard let first = rec.because.first else { return nil }
        return rec.because.count > 1 ? "Because you added \(first) and \(rec.because.count - 1) more" : "Because you added \(first)"
    }

    var body: some View {
        let r = rec.result
        // The card opens the detail page; the + sits beside it (not inside), so both can be focused.
        VStack(alignment: .leading, spacing: 0) {
        ZStack(alignment: .topTrailing) {
            DetailOpener(item: .preview(r), accessibilityLabel: accessibilityText) {
                VStack(alignment: .leading, spacing: 0) {
                    PosterImage(url: r.posterURL, title: r.title)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.primary.opacity(hovering ? 0.18 : 0.08), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(hovering ? 0.3 : 0.14), radius: 8, y: 5)
                        .scaleEffect(hovering && !reduceMotion ? 1.045 : 1)
                        .offset(y: hovering && !reduceMotion ? -4 : 0)

                    Text(r.title).font(.headline).lineLimit(1).padding(.top, 10)
                    Text("\(r.isTV ? "Series" : "Movie")\(r.year.map { " · \($0)" } ?? "")\(r.rating.map { " · ★ \($0.formatted(.number.precision(.fractionLength(1))))" } ?? "")")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).padding(.top, 1)
                    if let p = recommender.platform(for: r) {
                        PlatformLabel(platform: p)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .transition(.opacity)
                    }
                }
            }
            addButton
                .padding(8)
                .offset(y: hovering && !reduceMotion ? -4 : 0)
        }
            // Outside the card's tap area, so "and N more" can open its own list.
            if showReason { reasonView }
        }
        .modifier(HoverIf(on: !ScrollActivity.shared.isScrolling, hovering: $hovering))
        .task(id: rec.id) { await recommender.loadPlatform(for: rec.result, tmdb: model.tmdb) }
        #if DEBUG
        .task {
            // -BLShowSources "<title>" opens that card's "more" list, for checking without a mouse.
            if showReason, UserDefaults.standard.string(forKey: "BLShowSources") == rec.result.title {
                try? await Task.sleep(for: .seconds(1.5)); showSources = true
            }
        }
        #endif
        .contextMenu {
            Button { add() } label: { Label("Add to Up Next", systemImage: "plus") }
            Button { recommender.dismiss(rec) } label: { Label("Not Interested", systemImage: "hand.thumbsdown") }
        }
    }

    @ViewBuilder
    private var reasonView: some View {
        if let first = rec.because.first {
            let more = rec.because.count - 1
            if more > 0 {
                Button { showSources = true } label: {
                    Text("Because you added \(first) and \(Text("\(more) more").foregroundStyle(.tint))")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .help("See all \(rec.because.count) titles that led to this pick")
                .accessibilityLabel("Because you added \(first) and \(more) more. Show all.")
                .popover(isPresented: $showSources, arrowEdge: .bottom) {
                    SourcesPopover(rec: rec, library: library) { showSources = false }
                }
            } else {
                Text("Because you added \(first)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.top, 4)
            }
        }
    }

    private var accessibilityText: String {
        let r = rec.result
        var parts = [r.title, r.isTV ? "Series" : "Movie"]
        if let y = r.year { parts.append(String(y)) }
        if let p = recommender.platform(for: r) { parts.append("on \(p.rawValue)") }
        if let reason { parts.append(reason) }
        return parts.joined(separator: ", ")
    }

    /// Always visible (not hover-only), so keyboard and VoiceOver users can reach it.
    private var addButton: some View {
        Button { add() } label: {
            Image(systemName: adding ? "checkmark" : "plus")
                .font(.system(size: 13, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(hovering ? 0.65 : 0.45), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .help("Add to Up Next")
        .accessibilityLabel(adding ? "Added \(rec.result.title)" : "Add \(rec.result.title) to Up Next")
    }

    private func add() {
        guard !adding else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.4)) { adding = true }
        Task {
            _ = try? await model.add(rec.result, spottedOn: nil, source: "recommendation", context: context)
        }
    }
}

/// Every library title that led to a recommendation, strongest first. Each opens its page.
private struct SourcesPopover: View {
    @Environment(AppModel.self) private var model
    let rec: Recommendation
    let library: [String: Title]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Why \(rec.result.title)?").font(.headline).lineLimit(1)
                Text("Recommended alongside \(rec.because.count) titles in your library, strongest match first.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rec.because.indices, id: \.self) { i in
                        let name = rec.because[i]
                        let title = rec.becauseKeys.indices.contains(i) ? library[rec.becauseKeys[i]] : nil
                        Button {
                            guard let title else { return }
                            close()
                            model.openDetail(.title(title.persistentModelID))
                        } label: {
                            HStack(spacing: 10) {
                                PosterImage(url: title?.posterURL, cornerRadius: 4, maxPixel: 120).frame(width: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(name).lineLimit(1)
                                    if let title {
                                        Text("\(title.isTV ? "Series" : "Movie") · \(title.status.label)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                if title != nil {
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SourceRowStyle())
                        .disabled(title == nil)
                        .help(title == nil ? "" : "Open \(name)")
                        .overlay(alignment: .trailing) {
                            if let title { DislikeButton(title: title).padding(.trailing, 26) }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 300)
    }
}

/// Thumbs down for a title right from the "why" list: it stops counting toward recommendations.
private struct DislikeButton: View {
    @Bindable var title: Title
    var body: some View {
        let on = title.opinion == .disliked
        Button { withAnimation(.spring(duration: 0.35)) { title.opinion = on ? .none : .disliked } } label: {
            Image(systemName: on ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                .font(.callout)
                .foregroundStyle(on ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Use \(title.name) for recommendations again" : "Not for me: stop using \(title.name) for recommendations")
        .accessibilityLabel(on ? "Undo Not for Me for \(title.name)" : "Not for Me: \(title.name)")
    }
}

/// Highlights a row on hover, like a menu item.
private struct SourceRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0)))
            .onHover { hovering = $0 }
    }
}
