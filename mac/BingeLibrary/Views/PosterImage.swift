import SwiftUI

struct PosterImage: View {
    let url: String?
    var title: String = ""
    var cornerRadius: CGFloat = 10
    var maxPixel: Int = 600

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                // The grey placeholder and title are drawn only until the poster arrives, not underneath it.
                RemoteImage(url, maxPixel: maxPixel, placeholder: title)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension String {
    /// TMDB image URL at a different size, e.g. w342 → w780 for large displays.
    func tmdbSize(_ size: String) -> String {
        replacingOccurrences(of: #"/t/p/w\d+/"#, with: "/t/p/\(size)/", options: .regularExpression)
    }
}
