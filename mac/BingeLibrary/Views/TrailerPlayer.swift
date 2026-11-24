import SwiftUI
import WebKit

/// Lets SwiftUI ask a playing trailer where it is, e.g. to continue it full screen.
@MainActor
final class TrailerController {
    weak var web: WKWebView?

    func currentTime() async -> Double {
        guard let web else { return 0 }
        let value = try? await web.evaluateJavaScript("player && player.getCurrentTime ? player.getCurrentTime() : 0")
        return (value as? Double) ?? 0
    }
}

/// YouTube trailer that fills its frame.
/// - Hero mode (default): muted, no YouTube controls, ignores clicks and scrolling so the page still scrolls.
/// - Interactive mode: YouTube's own controls (pause, scrub, volume), used by the full-screen window.
struct TrailerPlayer: NSViewRepresentable {
    enum Event { case playing, paused, ended, failed }

    let key: String
    var muted: Bool
    var paused: Bool
    /// Bump to restart from the beginning.
    var restartToken: Int = 0
    var interactive = false
    var startAt: Double = 0
    var controller: TrailerController? = nil
    let onEvent: (Event) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeNSView(context: Context) -> PassthroughWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakHandler(context.coordinator), name: "bl")
        let web = PassthroughWebView(frame: .zero, configuration: config)
        web.interactive = interactive
        web.setValue(false, forKey: "drawsBackground")   // no white flash before the video starts
        // An https base URL gives YouTube the origin it requires for embedded playback.
        web.loadHTMLString(Self.html(key: key, muted: muted, interactive: interactive, start: startAt),
                           baseURL: URL(string: "https://bingelibrary.app"))
        context.coordinator.last = (muted, paused, restartToken)
        controller?.web = web
        return web
    }

    func updateNSView(_ web: PassthroughWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        controller?.web = web
        let (wasMuted, wasPaused, token) = context.coordinator.last
        if muted != wasMuted { web.evaluateJavaScript(muted ? "player&&player.mute()" : "player&&player.unMute()") }
        if paused != wasPaused { web.evaluateJavaScript(paused ? "player&&player.pauseVideo()" : "player&&player.playVideo()") }
        if restartToken != token { web.evaluateJavaScript("player&&(player.seekTo(0),player.playVideo())") }
        context.coordinator.last = (muted, paused, restartToken)
    }

    static func dismantleNSView(_ web: PassthroughWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "bl")
        web.loadHTMLString("", baseURL: nil)   // stop audio immediately
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onEvent: (Event) -> Void
        var last: (Bool, Bool, Int) = (true, false, 0)
        init(onEvent: @escaping (Event) -> Void) { self.onEvent = onEvent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String else { return }
            switch body {
            case "state:1": onEvent(.playing)
            case "state:2": onEvent(.paused)
            case "state:0": onEvent(.ended)
            default: if body.hasPrefix("error") { onEvent(.failed) }
            }
        }
    }

    /// Avoids a retain cycle between WKUserContentController and the coordinator.
    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            target?.userContentController(c, didReceive: m)
        }
    }

    private static func html(key: String, muted: Bool, interactive: Bool, start: Double) -> String {
        // Hero mode crops the video to cover the frame; interactive mode letterboxes it so nothing is cut off.
        let layout = interactive
            ? "#p{position:absolute;inset:0;width:100%;height:100%}"
            : "#p{position:absolute;top:50%;left:50%;width:100vw;height:56.25vw;min-height:100vh;min-width:177.78vh;transform:translate(-50%,-50%) scale(1.12);pointer-events:none}"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width">
        <style>html,body{margin:0;background:\(interactive ? "#000" : "transparent");overflow:hidden;height:100%}\(layout)</style></head>
        <body><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        function post(m){window.webkit.messageHandlers.bl.postMessage(m)}
        var player;
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('p',{videoId:'\(key)',
            playerVars:{autoplay:1,mute:1,controls:\(interactive ? 1 : 0),rel:0,playsinline:1,modestbranding:1,iv_load_policy:3,
                        disablekb:\(interactive ? 0 : 1),fs:0,cc_load_policy:0,start:\(Int(start)),origin:'https://bingelibrary.app'},
            events:{
              onReady:function(e){e.target.mute(); \(muted ? "" : "e.target.unMute();") e.target.playVideo()},
              onStateChange:function(e){post('state:'+e.data)},
              onError:function(e){post('error:'+e.data)}}})
        }
        </script></body></html>
        """
    }
}

/// A web view that, in hero mode, never takes clicks or scroll events.
final class PassthroughWebView: WKWebView {
    var interactive = false
    override func hitTest(_ point: NSPoint) -> NSView? { interactive ? super.hitTest(point) : nil }
    override func scrollWheel(with event: NSEvent) {
        if interactive { super.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }
}

// MARK: - Full-screen trailer window

/// What the full-screen trailer window is playing.
struct TheaterItem: Hashable {
    var key: String
    var title: String
    var start: Double
}

/// Contents of the trailer window. It enters full screen when it opens, and closes itself
/// when you leave full screen (Esc), returning you to the show's page.
struct TheaterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var window: NSWindow?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item = model.theater {
                TrailerPlayer(key: item.key, muted: false, paused: false, interactive: true, startAt: item.start) { _ in }
                    .ignoresSafeArea()
                    .id(item)
            }
        }
        .navigationTitle(model.theater.map { "\($0.title) — Trailer" } ?? "Trailer")
        .background(WindowFinder { window = $0 })
        .onChange(of: window) { _, w in
            guard let w else { return }
            w.backgroundColor = .black
            w.collectionBehavior.insert(.fullScreenPrimary)
            if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if (note.object as? NSWindow) === window { close() }
        }
        .onDisappear { model.theater = nil }
        .background { Button("") { close() }.keyboardShortcut(.cancelAction).hidden() }
    }

    private func close() {
        model.theater = nil
        dismissWindow(id: "trailer")
    }
}

/// Hands back the NSWindow hosting a SwiftUI view.
private struct WindowFinder: NSViewRepresentable {
    let found: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { found(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}
