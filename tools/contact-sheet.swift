// contact-sheet out.png columns cellWidth frame1.png "label 1" frame2.png "label 2" …
// Grid of frames (letterboxed to 16:9 cells) with a caption under each — used for the README use-case gallery.
import Foundation; import CoreGraphics; import ImageIO; import UniformTypeIdentifiers; import CoreText
let a = CommandLine.arguments
let out = a[1], cols = Int(a[2])!, cw = Double(a[3])!, ch = cw * 9 / 16, capH = 34.0, gap = 14.0
let items = stride(from: 4, to: a.count - 1, by: 2).map { (a[$0], a[$0 + 1]) }
let rows = (items.count + cols - 1) / cols
let W = Int(Double(cols) * cw + Double(cols + 1) * gap), H = Int(Double(rows) * (ch + capH) + Double(rows + 1) * gap)
let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
c.interpolationQuality = .high
let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 17, nil)
for (i, (path, label)) in items.enumerated() {
	let col = i % cols, row = i / cols
	let x = gap + Double(col) * (cw + gap), yTop = gap + Double(row) * (ch + capH + gap)
	let cell = CGRect(x: x, y: Double(H) - yTop - ch, width: cw, height: ch)
	c.setFillColor(CGColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1)); c.fill(cell)
	if let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) {
		let k = min(cw / Double(img.width), ch / Double(img.height)), w = Double(img.width) * k, h = Double(img.height) * k
		c.draw(img, in: CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h))
	}
	let str = NSAttributedString(string: label, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1)])
	c.textPosition = CGPoint(x: x + 2, y: cell.minY - 24); CTLineDraw(CTLineCreateWithAttributedString(str), c)
}
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, c.makeImage()!, nil); CGImageDestinationFinalize(d)
