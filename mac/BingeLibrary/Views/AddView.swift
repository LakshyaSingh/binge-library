import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The Add page, opened with the + button. Drop screenshots on the left; search results on the right.
struct AddView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @State private var choosingFiles = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    DropZone(choose: { choosingFiles = true })
                    if !model.reviewItems.isEmpty { reviewSection }
                }
                .padding(24)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            SearchResults()
                .frame(width: 320)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(model.detail == nil ? "Add Titles" : "")
        .navigationSubtitle(model.detail != nil ? "" : model.hasGemini ? "Screenshots are read by Gemini" : "Screenshots are read on this Mac")
        .toolbar {
            if model.detail == nil {
                ToolbarItem(placement: .navigation) {
                    Button { model.closeAdd() } label: { Label("Back", systemImage: "chevron.left") }
                        .help("Back to library (⌘[ or Esc)")
                }
            }
        }
        .background {
            if model.detail == nil {
                Button("") { model.closeAdd() }.keyboardShortcut(.cancelAction).hidden()
            }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.enqueue(urls: urls) }
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            Task { model.enqueue(await ImageUtils.loadImages(from: providers)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chooseScreenshots)) { _ in choosingFiles = true }
    }

    private var reviewSection: some View {
        let working = model.reviewItems.filter { $0.state == .queued || $0.state == .working }.count
        let selectable = model.reviewItems.filter { $0.state == .ready && !$0.selected.isEmpty }
        let selectedCount = selectable.reduce(0) { $0 + $1.selected.count }
        // Lazy, so only the cards on screen are built and laid out.
        return LazyVStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Review").font(.title2.bold())
                if working > 0 {
                    ProgressView().controlSize(.small)
                    Text("Reading \(working) screenshot\(working == 1 ? "" : "s")…").foregroundStyle(.secondary)
                } else {
                    Text("Tick the titles you want, then add them.").foregroundStyle(.secondary)
                }
                Spacer()
                if model.reviewItems.contains(where: { $0.state == .skipped || $0.allDone || ($0.state == .ready && $0.found.isEmpty) }) {
                    Button("Clear Done") { withAnimation(.spring(duration: 0.4)) { model.clearFinishedReviews() } }
                        .buttonStyle(.borderless)
                }
                if selectable.count > 1 {
                    Button("Add All Selected (\(selectedCount))") {
                        Task { for item in selectable { await model.addSelected(from: item, context: context) } }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            ForEach(model.reviewItems.filter { $0.state != .skipped }) { item in
                ScreenshotCard(item: item)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
        }
    }
}

private struct DropZone: View {
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(hovering ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: hovering)
                .scaleEffect(hovering ? 1.08 : 1)
            Text("Drop screenshots here").font(.title2.weight(.semibold))
            Text("Every title in a screenshot is found, including Netflix rows and lists. You can also paste with ⌘V or drop them on the Dock icon.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button("Choose Screenshots…", action: choose)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.quaternary.opacity(hovering ? 0.9 : 0.55)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.008 : 1)
        .animation(.spring(duration: 0.35, bounce: 0.3), value: hovering)
    }
}

/// One screenshot and every title found in it.
private struct ScreenshotCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Bindable var item: ReviewItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)
            if item.state == .ready && !item.found.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(item.found) { f in
                        FoundRow(found: f, platform: item.platform)
                        if f.id != item.found.last?.id { Divider().padding(.leading, 52) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }

    private var methodText: String {
        switch item.method {
        case .gemini: "Gemini"
        case .textRecognition: "text recognition"
        case .both: "Gemini and text recognition"
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else { Rectangle().fill(.quaternary) }
            }
            .frame(width: 150, height: 94, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.08)))

            VStack(alignment: .leading, spacing: 6) {
                switch item.state {
                case .queued, .working:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(item.state == .queued ? "Waiting…" : "Finding every title in this screenshot…").foregroundStyle(.secondary)
                    }
                    .frame(height: 94)
                case .failed(let message):
                    Text("Couldn’t read this one.").font(.headline)
                    Text(message).foregroundStyle(.secondary).lineLimit(3)
                default:
                    if item.found.isEmpty {
                        Text("No titles found.").font(.headline)
                        Text(item.detectedText.map { "It read “\($0)”. Try the search field above." } ?? "Try the search field above instead.")
                            .foregroundStyle(.secondary)
                    } else {
                        summary
                    }
                }
                if !item.notes.isEmpty {
                    Text(item.notes.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if item.state != .queued && item.state != .working && (item.found.isEmpty || item.allDone || item.selected.isEmpty) {
                Button("Dismiss") { withAnimation(.spring(duration: 0.4)) { item.state = .skipped } }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var summary: some View {
        let total = item.found.count
        let added = item.found.filter { $0.state == .added }.count
        let selected = item.selected
        let selectable = item.found.filter { $0.state == .ready && $0.match != nil }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(total == 1 ? "1 title found" : "\(total) titles found").font(.headline)
                    .contentTransition(.numericText())
                if added > 0 {
                    Text("· \(added) added").font(.headline).foregroundStyle(.green)
                        .contentTransition(.numericText())
                }
            }
            Text("Found by \(methodText)").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Picker("Platform", selection: $item.platform) {
                    Text("Platform Unknown").tag(Platform?.none)
                    Divider()
                    ForEach(Platform.allCases) { PlatformMenuLabel(platform: $0).tag(Platform?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Where these titles were spotted")
                if selectable.count > 1 {
                    let allOn = selectable.allSatisfy(\.include)
                    Button(allOn ? "Select None" : "Select All") {
                        withAnimation(.spring(duration: 0.3)) { selectable.forEach { $0.include = !allOn } }
                    }
                    .buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
                if !selected.isEmpty {
                    Button {
                        Task { await model.addSelected(from: item, context: context) }
                    } label: {
                        Text(selected.count == 1 ? "Add 1 Title" : "Add \(selected.count) Titles")
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(item.found.contains { $0.state == .adding })
                }
            }
            .animation(.spring(duration: 0.3), value: selected.count)
        }
    }
}

/// One title in a screenshot: tick to include, pick a different match, see if it's already in the library.
private struct FoundRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Bindable var found: FoundTitle
    let platform: Platform?

    var body: some View {
        let match = found.match
        // A set lookup, not a database query per row: with dozens of screenshots there are hundreds of rows.
        let inLibrary = match.map { model.libraryKeys.contains($0.id) } ?? false
        let canToggle = found.state == .ready && !inLibrary

        HStack(spacing: 12) {
            Toggle("Include \(match?.title ?? found.query)", isOn: $found.include)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canToggle)
                .opacity(canToggle ? 1 : 0.3)
                .frame(width: 20)

            Button { if let match { model.openDetail(.preview(match)) } } label: {
                PosterImage(url: match?.posterURL, title: "", cornerRadius: 4, maxPixel: 140).frame(width: 30)
            }
            .buttonStyle(.plain)
            .help("Show details")
            .accessibilityLabel("Show details for \(match?.title ?? found.query)")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(match?.title ?? found.query).font(.body.weight(.medium)).lineLimit(1).truncationMode(.tail)
                    if found.featured {
                        Text("FEATURED").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                if let match {
                    Text("\(match.isTV ? "Series" : "Movie")\(match.year.map { " · \($0)" } ?? "")\(match.rating.map { " · ★ \($0.formatted())" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .opacity(found.include || found.isDone || inLibrary ? 1 : 0.55)
            .layoutPriority(1)

            Spacer(minLength: 8)

            if found.candidates.count > 1 && found.state == .ready {
                Picker("Match", selection: $found.pick) {
                    ForEach(Array(found.candidates.enumerated()), id: \.offset) { i, c in
                        Text("\(c.title)\(c.year.map { " (\($0))" } ?? "") · \(c.isTV ? "TV" : "Movie")").tag(i)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 190)
                .help("Not the right one? Choose another match.")
            }

            status(inLibrary: inLibrary)
                .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onChange(of: inLibrary) { _, now in if now && found.state == .ready { found.include = false } }
        .animation(.spring(duration: 0.4, bounce: 0.3), value: found.state)
    }

    @ViewBuilder
    private func status(inLibrary: Bool) -> some View {
        switch found.state {
        case .adding:
            ProgressView().controlSize(.small)
        case .added:
            Label("Added", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating, value: found.state == .added)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        case .alreadyInLibrary:
            Label("In Library", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                .help("Already in your library, so it won’t be added again")
        case .failed(let message):
            Label("Failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).help(message)
        case .ready:
            if inLibrary {
                Label("In Library", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    .help("Already in your library, so it won’t be added again")
            } else if found.duplicateInBatch {
                Text("In another screenshot").font(.caption).foregroundStyle(.secondary)
                    .help("This title was also found in another screenshot above")
            } else {
                Button("Add") { Task { await model.add(found, platform: platform, context: context) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

/// Results for the toolbar search field while the Add page is open.
private struct SearchResults: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query private var titles: [Title]
    @State private var results: [TMDBResult] = []
    @State private var loading = false
    @State private var error: String?
    @State private var adding: String?

    var body: some View {
        let query = model.titleSearch.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Search").font(.title3.bold())
                Text(query.count >= 2 ? "Results for “\(query)”" : "Type in the search field above to find any movie or show.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(18)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 18)
            }
            List(results) { r in
                row(r)
                    .listRowSeparator(.hidden)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(.spring(duration: 0.4, bounce: 0.15), value: results.map(\.id))
            .overlay {
                if loading && results.isEmpty { ProgressView() }
                else if query.isEmpty {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.quaternary)
                } else if !loading && query.count >= 2 && results.isEmpty && error == nil {
                    Text("No results").foregroundStyle(.secondary)
                }
            }
        }
        .background(.background.secondary)
        .task(id: query) {
            guard query.count >= 2 else { results = []; error = nil; return }
            loading = true
            defer { loading = false }
            try? await Task.sleep(for: .milliseconds(300))   // debounce while typing
            guard !Task.isCancelled else { return }
            do { results = Array(try await model.tmdb.search(query).prefix(15)); error = nil }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }

    private func row(_ r: TMDBResult) -> some View {
        let inLibrary = titles.contains { $0.tmdbID == r.tmdbID && $0.mediaType == r.mediaType }
        return HStack(spacing: 10) {
            DetailOpener(item: .preview(r), accessibilityLabel: "\(r.title), \(r.isTV ? "Series" : "Movie")\(r.year.map { ", \($0)" } ?? "")") {
                HStack(spacing: 10) {
                    PosterImage(url: r.posterURL, cornerRadius: 4, maxPixel: 120).frame(width: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.body.weight(.medium)).lineLimit(1)
                        Text("\(r.isTV ? "Series" : "Movie")\(r.year.map { " · \($0)" } ?? "")\(r.rating.map { " · ★ \($0.formatted())" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            Spacer()
            if inLibrary {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Already in your library")
                    .accessibilityLabel("Already in your library")
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else if adding == r.id {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    adding = r.id
                    Task {
                        defer { adding = nil }
                        do { try await model.add(r, spottedOn: nil, source: "search", context: context) }
                        catch { self.error = error.localizedDescription }
                    }
                } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                .buttonStyle(.borderless)
                .help("Add to library")
                .accessibilityLabel("Add \(r.title) to library")
            }
        }
        .padding(.vertical, 3)
        .animation(.spring(duration: 0.4, bounce: 0.4), value: inLibrary)
    }
}
