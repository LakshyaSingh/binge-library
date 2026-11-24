import AppKit
import QuartzCore

/// Developer tool: launch with `-BLScrollTest YES` to scroll the library up and down
/// for 10 seconds at the display's refresh rate and report dropped frames.
/// Optional `-BLScrollReport <path>` writes the result to a file, then the app quits.
@MainActor
enum ScrollBenchmark {
    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "BLScrollTest") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { start() }
    }

    private static var driver: Driver?

    private static func start() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let root = window.contentView else { return finish("no window") }
        let scrollViews = allScrollViews(in: root)
        // With a detail page open, measure its scroll view (the frontmost one); otherwise the library grid.
        let detail = UserDefaults.standard.string(forKey: "BLOpenDetail") != nil
        guard let sv = detail ? scrollViews.last
                : scrollViews.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else {
            return finish("no scroll view")
        }
        // The driver scrolls programmatically, so tell the views a scroll is under way, as a real gesture would.
        ScrollActivity.shared.isScrolling = true
        let d = Driver(scrollView: sv)
        driver = d
        let link = sv.displayLink(target: d, selector: #selector(Driver.tick(_:)))
        link.add(to: .main, forMode: .common)
        d.link = link
    }

    private static func allScrollViews(in view: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let s = view as? NSScrollView { out.append(s) }
        for sub in view.subviews { out += allScrollViews(in: sub) }
        return out
    }

    static func finish(_ text: String) {
        print(text)
        if let path = UserDefaults.standard.string(forKey: "BLScrollReport") {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }

    final class Driver: NSObject {
        let scrollView: NSScrollView
        var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private var frameDuration: CFTimeInterval = 1.0 / 60
        private var intervals: [CFTimeInterval] = []
        private var y: CGFloat = 0
        private var direction: CGFloat = 1
        private var start: CFTimeInterval = 0

        init(scrollView: NSScrollView) { self.scrollView = scrollView }

        @MainActor @objc func tick(_ link: CADisplayLink) {
            let now = link.timestamp
            if start == 0 { start = now; frameDuration = link.targetTimestamp - link.timestamp }
            if last > 0 { intervals.append(now - last) }
            last = now

            // Move by real elapsed time so the speed is the same whatever the frame rate: ~2400 pt/s.
            let dt = intervals.last ?? frameDuration
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
            y += direction * 2400 * dt
            if y >= maxY { y = maxY; direction = -1 }
            if y <= 0 { y = 0; direction = 1 }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            if now - start > 10 { report(); link.invalidate() }
        }

        @MainActor private func report() {
            let hz = 1 / frameDuration
            let total = intervals.reduce(0, +)
            let fps = Double(intervals.count) / total
            // A frame is "dropped" for every extra refresh interval it took.
            let dropped = intervals.reduce(0) { $0 + max(0, Int(($1 / frameDuration).rounded()) - 1) }
            let hitches = intervals.filter { $0 > frameDuration * 1.5 }
            let worst = (intervals.max() ?? 0) * 1000
            let sorted = intervals.sorted()
            let p99 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.99)] * 1000
            let text = String(format: "display %.0f Hz | avg %.1f fps | dropped %d of %d frames (%.1f%%) | hitches %d | p99 %.1f ms | worst %.1f ms | content %.0f pt",
                              hz, fps, dropped, intervals.count + dropped, 100 * Double(dropped) / Double(intervals.count + dropped),
                              hitches.count, p99, worst, scrollView.documentView?.frame.height ?? 0)
            ScrollBenchmark.finish(text)
        }
    }
}
