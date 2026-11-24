import SwiftUI
import SwiftData
import Charts

/// Everything Year in Review shows for one year, worked out from the library.
struct YearStats {
    let year: Int
    let added: [Title]
    let watched: [Title]
    let minutes: Int
    let hoursAreEstimate: Bool
    let topGenres: [(Genre, Int)]
    let topServices: [(Platform, Int)]
    let bestRated: [Title]
    let liked: [Title]
    let biggestBinge: Title?
    let monthly: [(month: Int, added: Int, watched: Int)]
    let fromScreenshots: Int, fromSearch: Int, fromForYou: Int, fromAgents: Int

    var hours: Int { Int((Double(minutes) / 60).rounded()) }
    var movies: Int { watched.filter { !$0.isTV }.count }
    var series: Int { watched.filter(\.isTV).count }
    var isEmpty: Bool { added.isEmpty && watched.isEmpty }

    /// A playful title for the year, from the top genre.
    var persona: (name: String, line: String, symbol: String) {
        switch topGenres.first?.0 {
        case .mystery: ("The Detective", "Twists, secrets and whodunits kept you up.", "magnifyingglass")
        case .crime: ("The Case Cracker", "If there was a crime, you were on it.", "shield.lefthalf.filled")
        case .romance: ("The Romantic", "You were here for the love stories.", "heart.fill")
        case .comedy: ("The Laugh Seeker", "You chose a good laugh, again and again.", "face.smiling")
        case .drama: ("The Story Lover", "Big characters and bigger feelings.", "theatermasks.fill")
        case .sciFi: ("The Explorer", "Other worlds, other timelines, always more.", "sparkles")
        case .action: ("The Thrill Seeker", "Chases, fights and edge-of-your-seat moments.", "bolt.fill")
        case .documentary: ("The Curious Mind", "Real stories, told well.", "lightbulb.fill")
        case .horror: ("The Brave One", "You watched what others couldn’t.", "moon.haze.fill")
        case .animation: ("The Big Kid", "Animated, and proud of it.", "paintpalette.fill")
        case .reality: ("The People Watcher", "Real people, real drama.", "person.3.fill")
        case .history: ("The Time Traveler", "The past was your favorite channel.", "building.columns.fill")
        case .family: ("The Family Night Host", "Something everyone could watch.", "figure.2.and.child.holdinghands")
        case .music: ("The Music Lover", "Stories with a soundtrack.", "music.note")
        case .western: ("The Outlaw", "Dusty roads and showdowns.", "sun.dust.fill")
        case nil: ("The Collector", "Your watchlist grew all year.", "square.stack.3d.up.fill")
        }
    }

    init(year: Int, titles: [Title]) {
        let cal = Calendar.current
        func inYear(_ d: Date?) -> Bool { d.map { cal.component(.year, from: $0) == year } ?? false }
        self.year = year
        let added = titles.filter { inYear($0.addedAt) }
        let watched = titles.filter { inYear($0.watchedDate) }
        self.added = added
        self.watched = watched

        // Hours: movie runtimes plus every episode of watched series (assumes the whole show).
        var total = 0, estimated = false
        for t in watched {
            if let m = t.totalMinutes { total += m } else { total += t.isTV ? 8 * 45 : 110; estimated = true }
        }
        minutes = total
        hoursAreEstimate = estimated || watched.contains(where: \.isTV)

        let genreSource = watched.isEmpty ? added : watched
        var genres: [Genre: Int] = [:]
        for t in genreSource { for g in Genre.groups(names: t.genres) { genres[g, default: 0] += 1 } }
        topGenres = genres.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }

        var services: [Platform: Int] = [:]
        for t in added { if let p = t.watchPlatforms.first { services[p, default: 0] += 1 } }
        topServices = services.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) }

        bestRated = Array(watched.filter { $0.rating != nil }.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }.prefix(6))
        liked = Array((watched + added).filter { $0.opinion == .liked }.reduce(into: [Title]()) { list, t in
            if !list.contains(where: { $0 === t }) { list.append(t) }
        }.prefix(8))
        biggestBinge = watched.filter(\.isTV).max { ($0.totalMinutes ?? 0) < ($1.totalMinutes ?? 0) }

        monthly = (1...12).map { m in
            (m, added.filter { cal.component(.month, from: $0.addedAt) == m }.count,
             watched.filter { $0.watchedDate.map { cal.component(.month, from: $0) == m } ?? false }.count)
        }
        fromScreenshots = added.filter { $0.source == "screenshot" }.count
        fromSearch = added.filter { $0.source == "search" }.count
        fromForYou = added.filter { $0.source == "recommendation" }.count
        fromAgents = added.filter { $0.source == "agent" }.count
    }
}

/// A Wrapped-style look back at a year of watching.
struct YearInReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let titles: [Title]

    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var shown = false
    @State private var backfilling = false
    @State private var shareCard: Image?

    private var years: [Int] {
        let cal = Calendar.current
        var set = Set(titles.map { cal.component(.year, from: $0.addedAt) })
        for t in titles { if let d = t.watchedDate { set.insert(cal.component(.year, from: d)) } }
        set.insert(cal.component(.year, from: Date()))
        return set.sorted(by: >)
    }

    private var covered: Bool { model.detail != nil || model.addPresented }

    var body: some View {
        let stats = YearStats(year: year, titles: titles)
        Group {
            if stats.isEmpty {
                ContentUnavailableView {
                    Label("Nothing from \(String(year)) yet", systemImage: "calendar")
                } description: {
                    Text("Add titles and mark them Watched, and your year in review fills in here.")
                }
            } else {
                ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 22) {
                        hero(stats)
                        statTiles(stats)
                        HStack(alignment: .top, spacing: 22) {
                            genresCard(stats)
                            servicesCard(stats)
                        }
                        if !stats.bestRated.isEmpty { posterRow("Highest rated you watched", stats.bestRated) }
                        monthsCard(stats)
                        HStack(alignment: .top, spacing: 22) {
                            if let binge = stats.biggestBinge { bingeCard(binge) }
                            sourcesCard(stats)
                        }
                        if !stats.liked.isEmpty { posterRow("Your thumbs up", stats.liked) }
                        Text(footnote(stats))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("bottom")
                    }
                    .padding(28)
                    .frame(maxWidth: 1040)
                    .frame(maxWidth: .infinity)
                }
                #if DEBUG
                .task {
                    if UserDefaults.standard.bool(forKey: "BLReviewBottom") { try? await Task.sleep(for: .seconds(6)); withAnimation { reader.scrollTo("bottom", anchor: .bottom) } }
                }
                #endif
                }
            }
        }
        .navigationTitle(covered ? "" : "Year in Review")
        .navigationSubtitle(covered ? "" : String(year))
        .toolbar {
            if !covered {
                ToolbarItem {
                    Picker("Year", selection: $year) {
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .help("Choose a year")
                }
                if let shareCard, !stats.isEmpty {
                    ToolbarItem {
                        ShareLink(item: shareCard, preview: SharePreview("My \(String(year)) in Binge Library", image: shareCard)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .help("Share an image of your year")
                    }
                }
            }
        }
        .onAppear {
            if reduceMotion { shown = true } else { withAnimation(.spring(duration: 0.9, bounce: 0.15).delay(0.1)) { shown = true } }
        }
        .onChange(of: year) {
            shown = false
            if reduceMotion { shown = true } else { withAnimation(.spring(duration: 0.9, bounce: 0.15)) { shown = true } }
        }
        .task(id: year) {
            shareCard = shareImage(YearStats(year: year, titles: titles))
            await backfill()
            shareCard = shareImage(YearStats(year: year, titles: titles))
        }
    }

    // MARK: Sections

    private func hero(_ s: YearStats) -> some View {
        let p = s.persona
        return ZStack(alignment: .bottomLeading) {
            // A mosaic of this year's posters behind the title.
            HStack(spacing: 0) {
                ForEach(Array((s.watched + s.added).prefix(7).enumerated()), id: \.offset) { _, t in
                    // Each poster fills its slice of the banner, cropped rather than letterboxed.
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay { RemoteImage(t.posterURL, maxPixel: 500, placeholder: "") }
                        .clipped()
                }
            }
            .frame(height: 320)
            .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.05), location: 0),
                                            .init(color: .black.opacity(0.55), location: 0.45),
                                            .init(color: .black.opacity(0.9), location: 1)],
                                    startPoint: .top, endPoint: .bottom))

            VStack(alignment: .leading, spacing: 10) {
                Text("Your \(String(s.year)) in Binge Library")
                    .font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                Label(p.name, systemImage: p.symbol)
                    .font(.system(size: 44, weight: .heavy)).tracking(-1)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                    .foregroundStyle(.white)
                Text(p.line).font(.title3).foregroundStyle(.white.opacity(0.85))
            }
            .padding(28)
            .offset(y: shown || reduceMotion ? 0 : 20)
            .opacity(shown ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func statTiles(_ s: YearStats) -> some View {
        HStack(spacing: 16) {
            tile(value: s.hours, label: s.hoursAreEstimate ? "hours watched (about)" : "hours watched", symbol: "clock.fill", tint: .orange)
            tile(value: s.watched.count, label: "titles watched", symbol: "checkmark.circle.fill", tint: .green)
            tile(value: s.added.count, label: "added to your list", symbol: "plus.circle.fill", tint: .blue)
            tile(value: s.series, label: s.series == 1 ? "series finished" : "series finished", symbol: "tv.fill", tint: .purple)
            tile(value: s.movies, label: s.movies == 1 ? "movie watched" : "movies watched", symbol: "film.fill", tint: .pink)
        }
    }

    private func tile(value: Int, label: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint)
            Text("\(shown ? value : 0)")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
        .accessibilityElement(children: .combine)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    private func genresCard(_ s: YearStats) -> some View {
        card(s.watched.isEmpty ? "Top genres you added" : "Top genres you watched") {
            let top = s.topGenres.first?.1 ?? 1
            ForEach(Array(s.topGenres.enumerated()), id: \.offset) { i, item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(item.0.rawValue, systemImage: item.0.symbol).font(i == 0 ? .headline : .body)
                        Spacer()
                        Text("\(item.1)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    GeometryReader { geo in
                        Capsule().fill(Color.accentColor.opacity(i == 0 ? 1 : 0.45))
                            .frame(width: max(6, geo.size.width * CGFloat(item.1) / CGFloat(top) * (shown ? 1 : 0)))
                    }
                    .frame(height: 6)
                }
            }
        }
    }

    private func servicesCard(_ s: YearStats) -> some View {
        card("Where your titles stream") {
            if s.topServices.isEmpty {
                Text("No streaming info yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(s.topServices.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 12) {
                    PlatformLogo(platform: item.0, size: i == 0 ? 40 : 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.0.rawValue).font(i == 0 ? .headline : .body)
                        if i == 0 { Text("Your top service").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text("\(item.1) title\(item.1 == 1 ? "" : "s")").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func posterRow(_ title: String, _ list: [Title]) -> some View {
        card(title) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(list) { t in
                    DetailOpener(item: .title(t.persistentModelID), accessibilityLabel: t.accessibilityDescription) {
                        VStack(alignment: .leading, spacing: 6) {
                            PosterImage(url: t.posterURL, title: t.name)
                            Text(t.name).font(.callout.weight(.medium)).lineLimit(1)
                            if let r = t.rating {
                                Label(r.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: 140)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func monthsCard(_ s: YearStats) -> some View {
        card("Month by month") {
            Chart {
                ForEach(s.monthly, id: \.month) { m in
                    BarMark(x: .value("Month", Self.monthName(m.month)), y: .value("Titles", shown ? m.added : 0))
                        .foregroundStyle(by: .value("Kind", "Added"))
                        .position(by: .value("Kind", "Added"))
                    BarMark(x: .value("Month", Self.monthName(m.month)), y: .value("Titles", shown ? m.watched : 0))
                        .foregroundStyle(by: .value("Kind", "Watched"))
                        .position(by: .value("Kind", "Watched"))
                }
            }
            .chartForegroundStyleScale(["Added": Color.accentColor, "Watched": Color.green])
            .chartXScale(domain: (1...12).map(Self.monthName))
            .frame(height: 200)
            .accessibilityLabel("Titles added and watched each month")
        }
    }

    private func bingeCard(_ t: Title) -> some View {
        card("Biggest binge") {
            DetailOpener(item: .title(t.persistentModelID), accessibilityLabel: t.accessibilityDescription) {
                HStack(alignment: .top, spacing: 14) {
                    PosterImage(url: t.posterURL, title: t.name).frame(width: 90)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t.name).font(.headline)
                        if let n = t.episodeCount { Text("\(n) episodes").foregroundStyle(.secondary) }
                        if let m = t.totalMinutes {
                            Text("About \(Int((Double(m) / 60).rounded())) hours").font(.title2.bold()).padding(.top, 4)
                        }
                    }
                }
            }
        }
    }

    private func sourcesCard(_ s: YearStats) -> some View {
        card("How you added titles") {
            sourceRow("From screenshots", s.fromScreenshots, "photo.on.rectangle.angled")
            sourceRow("From search", s.fromSearch, "magnifyingglass")
            sourceRow("From For You", s.fromForYou, "sparkles")
            if s.fromAgents > 0 { sourceRow("By your AI agents", s.fromAgents, "cpu") }
        }
    }

    private func sourceRow(_ label: String, _ n: Int, _ symbol: String) -> some View {
        HStack {
            Label(label, systemImage: symbol)
            Spacer()
            Text("\(n)").font(.headline).monospacedDigit()
        }
    }

    private func footnote(_ s: YearStats) -> String {
        var parts: [String] = []
        if s.hoursAreEstimate { parts.append("Hours count every episode of the series you marked Watched, so they’re an estimate.") }
        parts.append("Titles marked Watched before watch dates were recorded (November 2026) count in the year they were added.")
        return parts.joined(separator: " ")
    }

    private static func monthName(_ m: Int) -> String { Calendar.current.shortMonthSymbols[m - 1] }

    // MARK: Data

    /// Fetch episode counts for watched series that don't have them yet, so hours are right.
    private func backfill() async {
        guard model.hasTMDB, !backfilling else { return }
        let missing = titles.filter { $0.isTV && $0.status == .watched && $0.episodeCount == nil }
        guard !missing.isEmpty else { return }
        backfilling = true
        defer { backfilling = false }
        for t in missing { _ = try? await model.refresh(t) }
    }

    // MARK: Sharing

    @MainActor
    private func shareImage(_ s: YearStats) -> Image {
        let renderer = ImageRenderer(content: ShareCard(stats: s).frame(width: 540, height: 675))
        renderer.scale = 2
        if let ns = renderer.nsImage { return Image(nsImage: ns) }
        return Image(systemName: "photo")
    }
}

/// The image you share: a compact summary of the year.
private struct ShareCard: View {
    let stats: YearStats

    var body: some View {
        let p = stats.persona
        VStack(alignment: .leading, spacing: 18) {
            Text("My \(String(stats.year)) in Binge Library").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            Label(p.name, systemImage: p.symbol).font(.system(size: 40, weight: .heavy)).foregroundStyle(.white)
            Text(p.line).font(.system(size: 18)).foregroundStyle(.white.opacity(0.85))
            Spacer()
            HStack(spacing: 28) {
                big("\(stats.hours)", "hours")
                big("\(stats.watched.count)", "watched")
                big("\(stats.added.count)", "added")
            }
            if let g = stats.topGenres.first {
                Text("Top genre: \(g.0.rawValue)").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            }
            if let s = stats.topServices.first {
                Text("Top service: \(s.0.rawValue)").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LinearGradient(colors: [Color(red: 0.04, green: 0.52, blue: 1), Color(red: 0.55, green: 0.2, blue: 0.85), Color(red: 1, green: 0.27, blue: 0.23)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func big(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 48, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(label).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        }
    }
}
