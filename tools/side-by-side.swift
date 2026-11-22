// side-by-side left.png right.png out.png [x y w h] [scale] [left-label] [right-label] — places two frames side by side (optional crop)
import Foundation; import CoreGraphics; import ImageIO; import UniformTypeIdentifiers; import CoreText
let a = CommandLine.arguments
// ffmpeg writes PNGs tagged BT.709; use the raw values (as sRGB) so the color mapping does not darken them
func load(_ p: String) -> CGImage { let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; let i = CGImageSourceCreateImageAtIndex(s, 0, nil)!; return i.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? i }
let L = load(a[1]), R = load(a[2])
var crop = CGRect(x: 0, y: 0, width: L.width, height: L.height)
if a.count >= 8 { crop = CGRect(x: Double(a[4])!, y: Double(a[5])!, width: Double(a[6])!, height: Double(a[7])!).intersection(CGRect(x: 0, y: 0, width: L.width, height: L.height)) }
let sc = a.count >= 9 ? Double(a[8])! : 1
let labelL = a.count >= 10 ? a[9] : "", labelR = a.count >= 11 ? a[10] : ""
let lb = labelL.isEmpty ? 0.0 : 44.0
let gap = 16.0, cw = crop.width * sc, ch = crop.height * sc
let W = Int(cw * 2 + gap), H = Int(ch + lb)
let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
c.interpolationQuality = .high
for (i, img) in [L, R].enumerated() {
  let sub = img.cropping(to: crop)!
  c.draw(sub, in: CGRect(x: Double(i) * (cw + gap), y: 0, width: cw, height: ch))
  let t = i == 0 ? labelL : labelR
  if !t.isEmpty {
    let f = CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil)
    let s = NSAttributedString(string: t, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)])
    c.textPosition = CGPoint(x: Double(i) * (cw + gap) + 12, y: ch + 12); CTLineDraw(CTLineCreateWithAttributedString(s), c)
  }
}
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, c.makeImage()!, nil); CGImageDestinationFinalize(d)
