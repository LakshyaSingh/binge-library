#if DEBUG
import AppKit
import SwiftData

/// Developer tool: launch with `-BLStallTest <folder>` to drop every image in the folder onto the
/// Add page, click "Add" on each screenshot as soon as it has been read, and record how long the
/// main thread ever stalls (the thing that makes scrolling and clicking freeze).
/// `-BLStallReport <path>` writes the result to a file, then the app quits.
/// `-BLNoGemini YES` reads screenshots on this Mac instead of with Gemini.
@MainActor
enum StallTest {
    static func runIfRequested(model: AppModel, context: ModelContext) {
        guard let folder = UserDefaults.standard.string(forKey: "BLStallTest") else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            let urls = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? [])
                .filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let before = (try? context.fetchCount(FetchDescriptor<Title>())) ?? 0
            let monitor = Monitor()
            monitor.start()
            let start = Date()
            model.enqueue(urls: urls)

            var clicked = Set<ObjectIdentifier>()
            var readAllAt: TimeInterval?
            while Date().timeIntervalSince(start) < 900 {
                try? await Task.sleep(for: .milliseconds(250))
                for item in model.reviewItems where item.state == .ready && !clicked.contains(ObjectIdentifier(item)) {
                    clicked.insert(ObjectIdentifier(item))
                    Task { await model.addSelected(from: item, context: context) }   // like clicking "Add"
                }
                let reading = model.reviewItems.contains { $0.state == .queued || $0.state == .working }
                if !reading, readAllAt == nil, model.reviewItems.count >= urls.count { readAllAt = Date().timeIntervalSince(start) }
                let adding = model.reviewItems.contains { $0.found.contains { $0.state == .adding } }
                let unclicked = model.reviewItems.contains { $0.state == .ready && !clicked.contains(ObjectIdentifier($0)) }
                if readAllAt != nil && !adding && !unclicked { break }
            }
            try? await Task.sleep(for: .seconds(1))
            let after = (try? context.fetchCount(FetchDescriptor<Title>())) ?? 0
            let total = Date().timeIntervalSince(start)
            let found = model.reviewItems.reduce(0) { $0 + $1.found.count }
            let s = monitor.stop()
            let report = """
            screenshots: \(urls.count), titles found: \(found), titles added: \(after - before)
            all read after: \(String(format: "%.1f", readAllAt ?? -1)) s, finished after: \(String(format: "%.1f", total)) s
            longest main-thread stall: \(Int(s.max * 1000)) ms
            stalls over 100 ms: \(s.over100), over 250 ms: \(s.over250), over 1 s: \(s.over1000)
            time frozen (stalls over 100 ms): \(String(format: "%.1f", s.frozen)) s of \(String(format: "%.1f", total)) s
            """
            if let path = UserDefaults.standard.string(forKey: "BLStallReport") {
                try? report.write(toFile: path, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            } else {
                print(report)
            }
        }
    }

    /// Fires every 5 ms on the main thread; any longer gap is time the app couldn't respond.
    final class Monitor {
        private var timer: Timer?
        private var last = CACurrentMediaTime()
        private(set) var max: Double = 0
        private(set) var over100 = 0, over250 = 0, over1000 = 0
        private(set) var frozen: Double = 0

        func start() {
            last = CACurrentMediaTime()
            let t = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        private func tick() {
            let now = CACurrentMediaTime()
            let gap = now - last - 0.005
            last = now
            if gap > max { max = gap }
            if gap > 0.1 { over100 += 1; frozen += gap }
            if gap > 0.25 { over250 += 1 }
            if gap > 1 { over1000 += 1 }
        }

        func stop() -> (max: Double, over100: Int, over250: Int, over1000: Int, frozen: Double) {
            timer?.invalidate()
            return (max, over100, over250, over1000, frozen)
        }
    }
}
#endif
