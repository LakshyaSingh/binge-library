import SwiftUI
import AppKit

/// The major streaming services the app recognizes and filters by.
enum Platform: String, CaseIterable, Identifiable, Codable {
    case netflix = "Netflix"
    case prime = "Prime Video"
    case appleTV = "Apple TV"
    case hulu = "Hulu"
    case max = "HBO Max"
    case disney = "Disney+"
    case peacock = "Peacock"
    case paramount = "Paramount+"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .netflix: Color(red: 0.898, green: 0.035, blue: 0.078)
        case .prime: Color(red: 0.0, green: 0.659, blue: 0.882)
        case .appleTV, .peacock: .primary
        case .hulu: Color(red: 0.11, green: 0.906, blue: 0.514)
        case .max: Color(red: 0.0, green: 0.169, blue: 0.906)
        case .disney: Color(red: 0.067, green: 0.235, blue: 0.812)
        case .paramount: Color(red: 0.0, green: 0.392, blue: 1.0)
        }
    }

    /// Link that opens this title on the service. Free data sources don't include each
    /// service's exact page ID, so this opens the service's own search for the title,
    /// where the show is the top result.
    func link(for title: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let q = title.addingPercentEncoding(withAllowedCharacters: allowed) ?? title
        let s: String = switch self {
        case .netflix: "https://www.netflix.com/search?q=\(q)"
        case .prime: "https://www.primevideo.com/search?phrase=\(q)"
        case .appleTV: "https://tv.apple.com/search?term=\(q)"
        case .hulu: "https://www.hulu.com/search?q=\(q)"
        case .max: "https://play.hbomax.com/search?q=\(q)"
        case .disney: "https://www.disneyplus.com/search?q=\(q)"
        case .peacock: "https://www.peacocktv.com/watch/search?q=\(q)"
        case .paramount: "https://www.paramountplus.com/search/?q=\(q)"
        }
        return URL(string: s)
    }

    /// Button tint; services whose brand color is black or white use the accent color.
    var tint: Color {
        switch self {
        case .appleTV, .peacock: .accentColor
        default: color
        }
    }

    /// Exact match for service names from TMDB (already normalized to our labels).
    /// Unlike `normalize`, "Amazon MX Player" or "Amazon Video" don't count as Prime Video.
    static func exact(_ name: String) -> Platform? {
        if let p = Platform(rawValue: name) { return p }
        return name == "Max" ? .max : nil   // stored before the HBO Max rename
    }

    /// Map loose names ("prime", "Amazon Prime Video", "Apple TV+") onto a platform.
    static func normalize(_ value: String?) -> Platform? {
        guard let s = value?.lowercased(), !s.isEmpty else { return nil }
        if s.contains("netflix") { return .netflix }
        if s.contains("prime") || s.contains("amazon") { return .prime }
        if s.contains("apple") { return .appleTV }
        if s.contains("hulu") { return .hulu }
        if s == "max" || s.contains("hbo") { return .max }
        if s.contains("disney") { return .disney }
        if s.contains("peacock") { return .peacock }
        if s.contains("paramount") { return .paramount }
        return nil
    }
}

/// The service's official logo (from TMDB, bundled at 332 px), as a small rounded tile.
struct PlatformLogo: View {
    let platform: Platform
    var size: CGFloat = 16

    var body: some View {
        // A bitmap pre-rendered at exactly this size (corners and outline included), so a grid full
        // of logos draws one small image each instead of resampling the full-size artwork every time.
        Group {
            if let cg = LogoCache.image(platform, size: size) {
                Image(decorative: cg, scale: LogoCache.scale)
            } else {
                Image(platform.logoAsset).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)   // the service name is always shown or spoken alongside
    }
}

@MainActor
enum LogoCache {
    static let scale: CGFloat = 2
    private static var cache: [String: CGImage] = [:]

    static func image(_ p: Platform, size: CGFloat) -> CGImage? {
        let key = "\(p.rawValue)|\(size)"
        if let hit = cache[key] { return hit }
        guard let source = NSImage(named: p.logoAsset)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let px = Int((size * scale).rounded())
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: px, height: px)
        let radius = CGFloat(px) * 0.225
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.interpolationQuality = .high
        ctx.addPath(path); ctx.clip()
        ctx.draw(source, in: rect)
        // Hairline outline so white logos still have an edge on a white background.
        ctx.resetClip()
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        ctx.addPath(CGPath(roundedRect: inset, cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 0.28))
        ctx.setLineWidth(1)
        ctx.strokePath()
        let image = ctx.makeImage()
        cache[key] = image
        return image
    }
}

/// Logo and name together.
struct PlatformLabel: View {
    let platform: Platform
    var logoSize: CGFloat = 14
    var body: some View {
        HStack(spacing: 5) {
            PlatformLogo(platform: platform, size: logoSize)
            Text(platform.rawValue)
        }
    }
}

extension Platform {
    var logoAsset: String {
        switch self {
        case .netflix: "Logos/Netflix"
        case .prime: "Logos/PrimeVideo"
        case .appleTV: "Logos/AppleTV"
        case .hulu: "Logos/Hulu"
        case .max: "Logos/HBOMax"
        case .disney: "Logos/DisneyPlus"
        case .peacock: "Logos/Peacock"
        case .paramount: "Logos/ParamountPlus"
        }
    }

    /// 16-pt rounded logo for menus and pop-up buttons, where images show at their natural size.
    @MainActor var menuIcon: NSImage { MenuIcons.icon(for: self) }
}

@MainActor
private enum MenuIcons {
    static var cache: [Platform: NSImage] = [:]
    static func icon(for p: Platform) -> NSImage {
        if let hit = cache[p] { return hit }
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 3.6, yRadius: 3.6).addClip()
            NSImage(named: p.logoAsset)?.draw(in: rect)
            return true
        }
        cache[p] = image
        return image
    }
}

/// Menu item / picker row: logo and name.
struct PlatformMenuLabel: View {
    let platform: Platform
    var prefix: String = ""
    var body: some View {
        Label { Text(prefix + platform.rawValue) } icon: { Image(nsImage: platform.menuIcon) }
    }
}
