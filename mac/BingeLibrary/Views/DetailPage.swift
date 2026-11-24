import SwiftUI
import SwiftData

/// Everything the detail page shows, from either a library title or a search preview.
struct ShowInfo {
    var tmdbID: Int
    var type: String
    var name: String
    var year: Int?
    var runtime: Int?
    var seasons: Int?
    var rating: Double?
    var genres: [String]
    var tagline: String
    var overview: String
    var poster: String?
    var backdrop: String?
    var providers: WatchProviders
    var region: String
    var trailerKey: String?
    /// Series: the next episode to air (date, season, episode).
    var nextAir: (date: Date, season: Int, episode: Int)? = nil
    var isTV: Bool { type == "tv" }

    /// "Season 3 starts Friday", "New episode tomorrow"… for upcoming episodes in the next 90 days.
    var upcoming: String? {
        guard let n = nextAir else { return nil }
        let days = AlertCenter.daysUntil(n.date)
        guard (0...90).contains(days) else { return nil }
        let when = AlertCenter.dayText(n.date)
        if n.episode == 1 && n.season == 1 { return days == 0 ? "Premieres today" : "Premieres \(when)" }
        if n.episode == 1 { return days == 0 ? "Season \(n.season) is out today" : "Season \(n.season) starts \(when)" }
        return "New episode \(when)"
    }

    var meta: String {
        var parts = [isTV ? "Series" : "Movie"]
        if let year { parts.append(String(year)) }
        if let runtime { parts.append("\(runtime / 60) hr \(runtime % 60) min") }
        if let seasons { parts.append("\(seasons) season\(seasons == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    var streamingPlatforms: [Platform] { providers.stream.compactMap { Platform.exact($0.name) } }
}

extension Title {
    var info: ShowInfo {
        ShowInfo(tmdbID: tmdbID, type: mediaType, name: name, year: year, runtime: runtime, seasons: seasons,
                 rating: rating, genres: genres, tagline: tagline, overview: overview, poster: posterURL,
                 backdrop: backdropURL, providers: providers, region: region, trailerKey: trailerKey,
                 nextAir: nextAirDate.flatMap { d in nextSeason.flatMap { s in nextEpisodeNumber.map { (d, s, $0) } } })
    }
}

extension TMDBDetails {
    var info: ShowInfo {
        ShowInfo(tmdbID: tmdbID, type: mediaType, name: title, year: year, runtime: runtime, seasons: seasons,
                 rating: rating, genres: genres, tagline: tagline, overview: overview, poster: posterURL,
                 backdrop: backdropURL, providers: providers, region: region, trailerKey: trailerKey,
                 nextAir: nextEpisode.map { ($0.airDate, $0.season, $0.episode) })
    }
}

/// Netflix-style full page for one movie or show. Zooms out of the poster you clicked; Back zooms into it again.
struct DetailPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let item: DetailItem
    let titles: [Title]

    @State private var details: TMDBDetails?
    @State private var error: String?
    @State private var busy = false
    @State private var confirmRemove = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrolledAway = false

    private var libraryTitle: Title? {
        switch item {
        case .title(let id): titles.first { $0.persistentModelID == id }
        case .preview(let r): titles.first { $0.tmdbID == r.tmdbID && $0.mediaType == r.mediaType }
        }
    }

    private var info: ShowInfo? { libraryTitle?.info ?? details?.info }

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            if let info {
                page(info)
            } else if let error {
                ContentUnavailableView("Couldn’t Load", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.closeDetail() } label: { Label("Back", systemImage: "chevron.left") }
                    .help("Back to library (⌘[ or Esc)")
            }
        }
        .background {
            // Esc goes back too.
            Button("") { model.closeDetail() }.keyboardShortcut(.cancelAction).hidden()
        }
        // Apple TV links open in the TV app rather than the default browser.
        .environment(\.openURL, OpenURLAction { url in
            LinkResolver.openInBestApp(url)
            return .handled
        })
        .task(id: libraryTitle?.persistentModelID) {
            // Titles added before trailers existed: look the trailer up once.
            guard let t = libraryTitle, !t.trailerChecked else { return }
            if let key = try? await model.tmdb.trailerKey(type: t.mediaType, id: t.tmdbID) { t.trailerKey = key }
            t.trailerChecked = true
        }
        .task(id: previewID) {
            guard libraryTitle == nil, case .preview(let r) = item else { return }
            do { details = try await model.tmdb.details(type: r.mediaType, id: r.tmdbID) }
            catch { self.error = error.localizedDescription }
        }
        .onAppear {
            // With Reduce Motion, content is simply there: no swing, no slide.
            if reduceMotion { appeared = true } else {
                withAnimation(.spring(duration: 0.6, bounce: 0.2).delay(0.12)) { appeared = true }
            }
        }
        .confirmationDialog("Remove “\(libraryTitle?.name ?? "")” from your library?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                guard let t = libraryTitle else { return }
                model.closeDetail()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { context.delete(t) }
            }
        }
    }

    private var previewID: String? {
        if case .preview(let r) = item { return r.id }
        return nil
    }

    // MARK: Page

    private func page(_ info: ShowInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Hero(backdrop: info.backdrop, trailerKey: info.trailerKey, title: info.name, scrolledAway: scrolledAway)

                // Poster + title overlapping the bottom of the hero
                HStack(alignment: .bottom, spacing: 26) {
                    PosterImage(url: info.poster?.tmdbSize("w500"), title: info.name, cornerRadius: 12, maxPixel: 900)
                        .frame(width: 180)
                        .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
                        .rotation3DEffect(.degrees(appeared ? 0 : -14), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                        .scaleEffect(appeared ? 1 : 0.9)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(info.name)
                            .font(.system(size: 44, weight: .bold))
                            .tracking(-0.8)
                            .lineLimit(3)
                            .minimumScaleFactor(0.6)
                        HStack(spacing: 10) {
                            Text(info.meta)
                            if let r = info.rating {
                                Label(r.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        if !info.genres.isEmpty {
                            Text(info.genres.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                        }
                        if let upcoming = info.upcoming {
                            Label(upcoming, systemImage: "calendar.badge.clock")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.tint)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.bottom, 6)
                    .offset(y: appeared ? 0 : 16)
                    .opacity(appeared ? 1 : 0)
                }
                .padding(.horizontal, 40)
                .padding(.top, -150)

                actions(info)
                    .task(id: "\(info.type):\(info.tmdbID)") { await LinkResolver.shared.load(type: info.type, id: info.tmdbID, name: info.name) }
                    .padding(.horizontal, 40)
                    .padding(.top, 28)
                    .offset(y: appeared ? 0 : 20)
                    .opacity(appeared ? 1 : 0)

                if let t = libraryTitle, t.isTV {
                    SeasonProgress(title: t)
                        .padding(.horizontal, 40)
                        .padding(.top, 18)
                        .offset(y: appeared ? 0 : 20)
                        .opacity(appeared ? 1 : 0)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 48) {
                        about(info).frame(maxWidth: 640, alignment: .leading)
                        WhereToWatch(info: info, title: libraryTitle).frame(width: 320)
                    }
                    VStack(alignment: .leading, spacing: 36) {
                        about(info)
                        WhereToWatch(info: info, title: libraryTitle)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 36)
                .padding(.bottom, 48)
                .offset(y: appeared ? 0 : 28)
                .opacity(appeared ? 1 : 0)
            }
        }
        .scrollEdgeEffectStyleCompat()
        .ignoresSafeArea(.container, edges: .top)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 360 } action: { _, away in scrolledAway = away }
    }

    @ViewBuilder
    private func actions(_ info: ShowInfo) -> some View {
        let platforms: [Platform] = {
            var out = libraryTitle?.watchPlatforms ?? []
            for p in info.streamingPlatforms where !out.contains(p) { out.append(p) }
            return out
        }()

        // The exact page on each service when we've found it, else that service's search.
        let resolver = LinkResolver.shared
        let link: (Platform) -> URL? = { p in
            resolver.url(for: p.rawValue, type: info.type, id: info.tmdbID) ?? p.link(for: info.name)
        }

        HStack(spacing: 12) {
            if let first = platforms.first, let url = link(first) {
                Link(destination: url) {
                    HStack(spacing: 8) {
                        PlatformLogo(platform: first, size: 20)
                        Text("Open in \(first.rawValue)")
                    }
                    .font(.headline)
                    .padding(.horizontal, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(first.tint)
                .controlSize(.extraLarge)
                .help("Opens “\(info.name)” in \(first.rawValue)")
            }
            ForEach(platforms.dropFirst().prefix(2)) { p in
                if let url = link(p) {
                    Link(destination: url) {
                        HStack(spacing: 7) {
                            PlatformLogo(platform: p, size: 18)
                            Text(p.rawValue)
                        }
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.extraLarge)
                        .help("Opens “\(info.name)” in \(p.rawValue)")
                }
            }

            if let t = libraryTitle {
                StatusControl(title: t)
                OpinionControl(title: t)
            } else {
                Button {
                    guard case .preview(let r) = item else { return }
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            let t = try await model.add(r, spottedOn: nil, source: "search", context: context).title
                            withAnimation(.spring(duration: 0.4, bounce: 0.3)) { model.detail = .title(t.persistentModelID) }
                        } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    Label(busy ? "Adding…" : "Add to Library", systemImage: "plus")
                }
                .buttonStyle(platforms.isEmpty ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.bordered))
                .controlSize(.extraLarge)
                .disabled(busy)
            }

            Spacer(minLength: 0)

            Menu {
                if let t = libraryTitle {
                    Menu("Spotted On") {
                        Button("None") { t.platform = nil }
                        ForEach(Platform.allCases) { p in
                            Toggle(isOn: Binding(get: { t.platform == p }, set: { if $0 { t.platform = p } })) {
                                PlatformMenuLabel(platform: p)
                            }
                        }
                    }
                    Button("Refresh Streaming Info") {
                        Task { busy = true; defer { busy = false }; try? await model.refresh(t) }
                    }
                    Divider()
                }
                if let link = info.providers.link, let url = URL(string: link) {
                    Link("Open in JustWatch", destination: url)
                }
                Link("View on TMDB", destination: URL(string: "https://www.themoviedb.org/\(info.type)/\(info.tmdbID)")!)
                if libraryTitle != nil {
                    Divider()
                    Button("Remove from Library…", role: .destructive) { confirmRemove = true }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
            .menuIndicator(.hidden)
            .controlSize(.extraLarge)
            .fixedSize()
            .help("More")
        }
    }

    private func about(_ info: ShowInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !info.tagline.isEmpty {
                Text(info.tagline).font(.title2.weight(.semibold)).tracking(-0.3)
            }
            Text(info.overview.isEmpty ? "No summary available." : info.overview)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let t = libraryTitle {
                Text("Added \(t.addedAt.formatted(date: .abbreviated, time: .omitted)) from \(t.source == "screenshot" ? "a screenshot" : t.source == "recommendation" ? "For You" : "search")\(t.platform.map { " · Spotted on \($0.rawValue)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
    }
}

/// Large backdrop that turns into the trailer after a moment, like Netflix.
/// The backdrop has parallax on scroll and stretches when you pull down.
private struct Hero: View {
    @Environment(AppModel.self) private var model
    let backdrop: String?
    let trailerKey: String?
    let title: String
    /// True once the page has scrolled the hero out of view, so the trailer pauses.
    let scrolledAway: Bool

    @AppStorage("autoplayTrailers") private var autoplay = true
    @AppStorage("trailerMuted") private var muted = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = false
    @State private var playing = false
    @State private var ended = false
    @State private var failed = false
    @State private var restart = 0
    @State private var userPaused = false
    @State private var controller = TrailerController()
    private let height: CGFloat = 440

    private var isPaused: Bool { userPaused || scrolledAway || model.theater != nil }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            RemoteImage(backdrop, maxPixel: 2000)
                .visualEffect { [reduceMotion] content, proxy in
                    let minY = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    return content
                        // Stretch on pull-down and parallax on scroll — both off with Reduce Motion.
                        .scaleEffect(minY > 0 && !reduceMotion ? 1 + minY / height : 1, anchor: .bottom)
                        .offset(y: reduceMotion ? 0 : (minY > 0 ? 0 : -minY * 0.4))
                }
            // The page sets model.detail to nil as it closes; drop the web view first so it never
            // gets caught in the zoom-out animation.
            if started, let trailerKey, !failed, model.detail != nil {
                TrailerPlayer(key: trailerKey, muted: muted || model.theater != nil, paused: isPaused, restartToken: restart,
                              controller: controller) { event in
                    withAnimation(.easeInOut(duration: 0.8)) {
                        switch event {
                        case .playing: playing = true; ended = false
                        case .paused: break
                        case .ended: playing = false; ended = true
                        case .failed: playing = false; failed = true
                        }
                    }
                }
                .opacity(playing || userPaused ? 1 : 0)
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Click the trailer to pause or resume it.
            guard started, playing || userPaused else { return }
            withAnimation(.spring(duration: 0.3, bounce: 0.3)) { userPaused.toggle() }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .bottom) {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Color(nsColor: .windowBackgroundColor), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: height * 0.6)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) { controls.padding(.trailing, 40).padding(.bottom, 165) }
        .task(id: trailerKey) {
            // Reduce Motion also means no autoplaying video; the Play Trailer button is there instead.
            guard autoplay, !reduceMotion, trailerKey != nil else { return }
            // Let the zoom-in finish first, then start the trailer.
            try? await Task.sleep(for: .seconds(1.4))
            started = true
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "BLTestFullScreen") {
                try? await Task.sleep(for: .seconds(6))
                openFullScreen()
            }
            #endif
        }
    }

    @ViewBuilder
    private var controls: some View {
        if trailerKey != nil && !failed {
            HStack(spacing: 10) {
                if playing || userPaused {
                    HeroButton(symbol: userPaused ? "play.fill" : "pause.fill",
                               help: userPaused ? "Play" : "Pause") { userPaused.toggle() }
                    HeroButton(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                               help: muted ? "Turn sound on" : "Mute") { muted.toggle() }
                    HeroButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Watch full screen") { openFullScreen() }
                } else if ended || !started {
                    HeroButton(symbol: ended ? "arrow.counterclockwise" : "play.fill", label: ended ? "Replay Trailer" : "Play Trailer",
                               help: "Play the trailer") {
                        if started { restart += 1; ended = false } else { started = true }
                    }
                    HeroButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Watch full screen") { openFullScreen() }
                }
            }
            .transition(.scale.combined(with: .opacity))
            .animation(.spring(duration: 0.4, bounce: 0.3), value: playing)
            .animation(.spring(duration: 0.4, bounce: 0.3), value: ended)
            .animation(.spring(duration: 0.4, bounce: 0.3), value: userPaused)
        }
    }

    /// Continue the trailer, with sound and full controls, in its own full-screen window.
    private func openFullScreen() {
        guard let trailerKey else { return }
        Task {
            let time = (playing || userPaused) && !ended ? await controller.currentTime() : 0
            withAnimation(.spring(duration: 0.3)) { userPaused = true }
            model.theater = TheaterItem(key: trailerKey, title: title, start: time)
            model.openTrailerWindow?()
        }
    }
}

private struct HeroButton: View {
    let symbol: String
    var label: String? = nil
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).contentTransition(.symbolEffect(.replace))
                if let label { Text(label) }
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, label == nil ? 0 : 14)
            .frame(minWidth: 36, minHeight: 36)
            .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(hovering ? 0.6 : 0.3)))
            .environment(\.colorScheme, .dark)
            .scaleEffect(hovering ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.3, bounce: 0.4)) { hovering = h } }
        .help(help)
        .accessibilityLabel(label ?? help)
    }
}

/// The standard segmented control: familiar, keyboard-accessible, and read correctly by VoiceOver.
private struct StatusControl: View {
    @Bindable var title: Title

    var body: some View {
        Picker("Status", selection: Binding(get: { title.status },
                                            set: { new in withAnimation(AppModel.motion) { title.status = new } })) {
            ForEach(WatchStatus.allCases) { s in
                Label(s.label, systemImage: s.symbol).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.extraLarge)
        .fixedSize()
        .help("Watching status")
    }
}

/// Thumbs up / thumbs down. Click the active one again to clear it.
struct OpinionControl: View {
    @Bindable var title: Title
    var controlSize: ControlSize = .extraLarge

    var body: some View {
        HStack(spacing: 6) {
            button(.liked, symbol: "hand.thumbsup", help: "I like this. Recommendations lean toward titles like it.")
            button(.disliked, symbol: "hand.thumbsdown", help: "Not for me. It won’t be used for recommendations.")
        }
    }

    private func button(_ opinion: Opinion, symbol: String, help: String) -> some View {
        let active = title.opinion == opinion
        return Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.4)) { title.opinion = active ? .none : opinion }
        } label: {
            Image(systemName: active ? symbol + ".fill" : symbol)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: active)
                .frame(minWidth: 18)
        }
        .buttonStyle(.bordered)
        .tint(active ? (opinion == .liked ? .accentColor : .secondary) : nil)
        .controlSize(controlSize)
        .help(active ? "\(help) Click again to clear." : help)
        .accessibilityLabel(opinion.label)
        .accessibilityValue(active ? "Selected" : "Not selected")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct WhereToWatch: View {
    @Environment(AppModel.self) private var model
    let info: ShowInfo
    let title: Title?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where to Watch").font(.title2.bold())
                Text(info.region).font(.caption).foregroundStyle(.secondary)
            }
            if info.providers.isEmpty {
                Text("No US streaming info right now.").foregroundStyle(.secondary)
                if let p = title?.platform, let url = p.link(for: info.name) {
                    ProviderRow(name: p.rawValue, logo: nil, platform: p, url: url)
                }
            } else {
                section("Stream", info.providers.stream)
                section("Rent", info.providers.rent)
                section("Buy", info.providers.buy)
            }
            Text("Opens this title on each service. Data from JustWatch via TMDB.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func section(_ label: String, _ list: [ProviderInfo]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
                ForEach(list, id: \.name) { p in
                    let platform = Platform.exact(p.name)
                    if let url = LinkResolver.shared.url(for: p.name, type: info.type, id: info.tmdbID)
                        ?? platform?.link(for: info.name) ?? info.providers.link.flatMap(URL.init(string:)) {
                        ProviderRow(name: p.name, logo: p.logoURL, platform: platform, url: url)
                    }
                }
            }
        }
    }
}

private struct ProviderRow: View {
    let name: String
    let logo: String?
    let platform: Platform?
    let url: URL
    @State private var hovering = false

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Group {
                    if let platform {
                        // Bundled full-resolution logo for the major services…
                        PlatformLogo(platform: platform, size: 34)
                    } else {
                        // …and TMDB's 300 px logo (not the old 92 px one) for everyone else.
                        ZStack {
                            RoundedRectangle(cornerRadius: 34 * 0.225, style: .continuous).fill(.quaternary)
                            if let logo { RemoteImage(logo.tmdbSize("w300"), maxPixel: 300) }
                        }
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 34 * 0.225, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 34 * 0.225, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                    }
                }
                Text(name).font(.body.weight(.medium)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .offset(x: hovering ? 2 : 0, y: hovering ? -2 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.3, bounce: 0.3)) { hovering = h } }
        .help("Open \(name)")
    }
}

/// Type-erased button style so a single button can switch between prominent and bordered.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Simple wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension View {
    /// Soft scroll edge under the toolbar on newer macOS; no-op elsewhere.
    @ViewBuilder func scrollEdgeEffectStyleCompat() -> some View {
        if #available(macOS 26.0, *) { self.scrollEdgeEffectStyle(.soft, for: .top) } else { self }
    }
}
