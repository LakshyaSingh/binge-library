// On-device OCR using Apple's Vision framework. Usage: ocr <image-path>
// Prints JSON: [{ "text": String, "confidence": Double, "height": Double, "y": Double }]
import Foundation
import Vision
import AppKit

guard CommandLine.arguments.count > 1 else {
  FileHandle.standardError.write("usage: ocr <image>\n".data(using: .utf8)!)
  exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOf: url),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
  FileHandle.standardError.write("could not read image\n".data(using: .utf8)!)
  exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true

let handler = VNImageRequestHandler(cgImage: cg, options: [:])
do { try handler.perform([request]) } catch {
  FileHandle.standardError.write("ocr failed: \(error)\n".data(using: .utf8)!)
  exit(1)
}

var out: [[String: Any]] = []
for obs in request.results ?? [] {
  guard let top = obs.topCandidates(1).first else { continue }
  let box = obs.boundingBox // normalized, origin bottom-left
  out.append([
    "text": top.string,
    "confidence": Double(top.confidence),
    "height": Double(box.height),
    "width": Double(box.width),
    "y": Double(1 - box.maxY)
  ])
}
let data = try JSONSerialization.data(withJSONObject: out, options: [])
FileHandle.standardOutput.write(data)
