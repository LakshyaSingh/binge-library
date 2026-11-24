import AppKit
import ImageIO
import SwiftUI

/// Fast poster loading: disk cache for downloads, memory cache for decoded images,
/// decoding on a background thread, and de-duplicated in-flight requests.
actor ImagePipeline {
    static let shared = ImagePipeline()

    nonisolated private let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 400 << 20
        return cache
    }()

    private var inflight: [String: Task<NSImage?, Never>] = [:]

    private let session: URLSession = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Images")
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 1 << 30, directory: dir)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    nonisolated private func key(_ url: URL, _ maxPixel: Int) -> NSString { "\(maxPixel)|\(url.absoluteString)" as NSString }

    /// Synchronous memory-cache lookup, so cached posters render on the very first frame.
    nonisolated func cached(_ url: URL, maxPixel: Int) -> NSImage? {
        memory.object(forKey: key(url, maxPixel))
    }

    func image(_ url: URL, maxPixel: Int) async -> NSImage? {
        let k = key(url, maxPixel)
        if let hit = memory.object(forKey: k) { return hit }
        if let running = inflight[k as String] { return await running.value }
        let session = self.session
        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let (data, _) = try? await session.data(from: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,   // decode now, off the main thread
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        inflight[k as String] = task
        let image = await task.value
        inflight[k as String] = nil
        if let image {
            memory.setObject(image, forKey: k, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }

    /// Warm the cache ahead of scrolling.
    func prefetch(_ urls: [URL], maxPixel: Int) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for url in urls where memory.object(forKey: key(url, maxPixel)) == nil {
                if running >= 6 { await group.next(); running -= 1 }
                group.addTask { _ = await self.image(url, maxPixel: maxPixel) }
                running += 1
            }
        }
    }
}

/// Drop-in replacement for AsyncImage backed by ImagePipeline.
struct RemoteImage: View {
    let url: URL?
    let maxPixel: Int
    /// When set, a grey tile with this text shows until the image loads (posters).
    let placeholder: String?
    @State private var image: NSImage?

    init(_ url: String?, maxPixel: Int = 600, placeholder: String? = nil) {
        let u = url.flatMap(URL.init(string:))
        self.url = u
        self.maxPixel = maxPixel
        self.placeholder = placeholder
        _image = State(initialValue: u.flatMap { ImagePipeline.shared.cached($0, maxPixel: maxPixel) })
    }

    var body: some View {
        ZStack {
            if image == nil, let placeholder {
                Rectangle().fill(.quaternary)
                if !placeholder.isEmpty {
                    Text(placeholder)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(8)
                }
            }
            if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // Drawing the decoded bitmap directly is cheaper than going through NSImage.
                Image(decorative: cg, scale: 2)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = ImagePipeline.shared.cached(url, maxPixel: maxPixel) { image = hit; return }
            let loaded = await ImagePipeline.shared.image(url, maxPixel: maxPixel)
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }
}

