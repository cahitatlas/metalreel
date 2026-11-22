// mae a.png b.png — mean absolute difference (0-255) over the whole frame, and the worst 64x64 block
import Foundation; import CoreGraphics; import ImageIO
func load(_ p: String) -> ([UInt8], Int, Int) {
  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; let im = CGImageSourceCreateImageAtIndex(src, 0, nil)!
  let w = im.width, h = im.height; var buf = [UInt8](repeating: 0, count: w*h*4)
  let c = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  c.draw(im, in: CGRect(x:0,y:0,width:w,height:h)); return (buf, w, h) }
let (A, w, h) = load(CommandLine.arguments[1]); let (B, w2, h2) = load(CommandLine.arguments[2])
guard w == w2, h == h2 else { print("size differs"); exit(1) }
var d = 0.0; var worst = (0.0, 0, 0)
for by in stride(from: 0, to: h - 63, by: 64) { for bx in stride(from: 0, to: w - 63, by: 64) { var s = 0.0
  for y in by..<by+64 { for x in bx..<bx+64 { let i = (y*w+x)*4; for c in 0..<3 { s += abs(Double(A[i+c]) - Double(B[i+c])) } } }
  d += s; let m = s / (64*64*3); if m > worst.0 { worst = (m, bx, by) } } }
print(String(format: "MAE=%.2f worst=%.1f@(%d,%d)", d / Double((w/64)*(h/64)*64*64*3), worst.0, worst.1, worst.2))
