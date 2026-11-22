// extract-frame video.mp4 seconds out.jpg — saves one decoded frame as JPEG (used to make sample photos).
import Foundation; import AVFoundation; import ImageIO; import UniformTypeIdentifiers
let a = CommandLine.arguments
let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: a[1])))
gen.appliesPreferredTrackTransform = true; gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
let img = try gen.copyCGImage(at: CMTime(seconds: Double(a[2])!, preferredTimescale: 600), actualTime: nil)
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[3]) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary); CGImageDestinationFinalize(d)
