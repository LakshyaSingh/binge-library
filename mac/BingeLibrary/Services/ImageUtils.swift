import Foundation
import ImageIO
import UniformTypeIdentifiers
import AppKit

enum ImageUtils {
    /// Decode any image (PNG, JPEG, HEIC…) downscaled to `maxPixels` on the long edge.
    static func cgImage(from data: Data, maxPixels: Int = 2048) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.85) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func thumbnail(from data: Data) -> NSImage? {
        guard let cg = cgImage(from: data, maxPixels: 600) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Pull image data out of drag-and-drop / paste providers (files from Finder or raw images from other apps).
    static func loadImages(from providers: [NSItemProvider]) async -> [Data] {
        var out: [Data] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadURL(provider), let data = try? Data(contentsOf: url),
               UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? (cgImage(from: data) != nil) {
                out.append(data)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let data = await loadData(provider) {
                out.append(data)
            }
        }
        return out
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }

    private static func loadData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in cont.resume(returning: data) }
        }
    }
}
