// diff-map a.png b.png out.png [gain] — per-pixel difference heat map (black = identical, yellow/white = large).
// Prints the mean absolute error (0–255) over RGB, the same number tools/mae.swift reports.
import Foundation; import CoreGraphics; import ImageIO; import UniformTypeIdentifiers
func load(_ p: String) -> ([UInt8], Int, Int) {
	let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; let im = CGImageSourceCreateImageAtIndex(src, 0, nil)!
	let w = im.width, h = im.height; var buf = [UInt8](repeating: 0, count: w * h * 4)
	let c = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
	c.draw(im, in: CGRect(x: 0, y: 0, width: w, height: h)); return (buf, w, h)
}
let a = CommandLine.arguments
let (A, w, h) = load(a[1]), (B, w2, h2) = load(a[2])
guard w == w2, h == h2 else { print("size mismatch"); exit(1) }
let gain = a.count > 4 ? Double(a[4])! : 4
var out = [UInt8](repeating: 255, count: w * h * 4), sum = 0.0
for i in stride(from: 0, to: w * h * 4, by: 4) {
	var d = 0.0; for c in 0..<3 { d += abs(Double(A[i + c]) - Double(B[i + c])) }
	sum += d; let v = min(1, d / 3 / 255 * gain)
	// inferno-like ramp: black → purple → orange → yellow
	out[i] = UInt8(min(255, 255 * min(1, v * 1.6))); out[i + 1] = UInt8(255 * max(0, min(1, (v - 0.35) * 1.6))); out[i + 2] = UInt8(255 * max(0, min(1, v < 0.5 ? v * 1.4 : (1 - v) * 1.4)))
}
let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dst, ctx.makeImage()!, nil); CGImageDestinationFinalize(dst)
print(String(format: "MAE=%.2f", sum / Double(w * h * 3)))
