import Foundation
import Vision
import CoreGraphics

/// On-device fallback: Apple's Vision text recognition. Free and offline.
enum TextRecognizer {
    struct Line {
        var text: String
        var confidence: Float
        var height: CGFloat
        var y: CGFloat   // 0 = top of the image
    }

    static func lines(in image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return Line(text: top.string, confidence: top.confidence,
                        height: obs.boundingBox.height, y: 1 - obs.boundingBox.maxY)
        }
    }

    private static let platformHints: [(String, Platform)] = [
        ("netflix|only on netflix", .netflix),
        ("prime video|included with prime|^prime$|amazon original|watch with prime", .prime),
        ("apple tv\\+?|^tv\\+$|apple original", .appleTV),
        ("\\bhulu\\b", .hulu),
        ("hbo max|^max$|max original", .max),
        ("disney\\+|disney plus", .disney),
        ("peacock", .peacock),
        ("paramount\\+", .paramount),
    ]

    /// UI chrome that is never a title.
    private static let noise = #"^(play|resume|watch now|more info|my list|episodes?|trailers? (&|and) more|more like this|details|season \d+|s\d+:? ?e\d+|home|tv shows|movies|new (&|and) popular|search|browse|continue watching|top 10|trending|hd|4k|uhd|dolby.*|audio description|subtitles?|cc|ad|\d{4}|\d+h ?\d*m|\d+ seasons?|\d+ episodes?|cast:?.*|genres?:?.*|starring:?.*|director:?.*|creators?:?.*|this (show|movie) is:?.*|watch (later|offline)|download|rate|share|add to watchlist|watchlist|free trial|subscribe|start watching|included with.*|rent|buy|sign in|profile|kids|categories|store|for you|library|apple tv\+?|netflix|prime video|prime|r|pg(-13)?|nc-17)$"#
    private static let meta = #"\d+% match|\b(tv-(ma|14|pg|y7?|g)|pg-13)\b|^n\s+(series|film|documentary)$"#

    private static func has(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func analyze(_ lines: [Line]) -> (platform: Platform?, candidates: [String]) {
        let all = lines.map(\.text).joined(separator: "\n")
        let platform = platformHints.first { pattern, _ in
            lines.contains { has(pattern, $0.text.trimmingCharacters(in: .whitespaces)) } || has(pattern, all)
        }?.1

        let scored = lines.compactMap { line -> (String, CGFloat)? in
            let text = line.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard (2...60).contains(text.count), !has(noise, text), !has(meta, text),
                  text.range(of: "[a-zA-Z]", options: .regularExpression) != nil,
                  !has(#"[.,;]$"#, text),                           // sentence fragments from descriptions
                  text.split(separator: " ").count <= 9 else { return nil }
            // Bigger text is more likely the title; small bonus for being near the top and for confidence.
            let score = line.height * (1 + (1 - line.y) * 0.3) * CGFloat(0.5 + line.confidence / 2)
            return (text, score)
        }.sorted { $0.1 > $1.1 }

        var seen = Set<String>()
        let unique = scored.map(\.0).filter { seen.insert($0.lowercased()).inserted }
        return (platform, Array(unique.prefix(12)))
    }
}
