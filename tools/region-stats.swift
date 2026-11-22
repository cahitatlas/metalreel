import Foundation; import CoreGraphics; import ImageIO
func load(_ p: String) -> (UnsafeMutablePointer<UInt8>, Int, Int) {
  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; let im = CGImageSourceCreateImageAtIndex(src, 0, nil)!
  let w = im.width, h = im.height; let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: w*h*4)
  let c = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: (im.colorSpace?.model == .rgb ? im.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.draw(im, in: CGRect(x:0,y:0,width:w,height:h)); return (buf, w, h) }
let a = CommandLine.arguments; let (A, w, h) = load(a[1]); let (B, _, _) = load(a[2])
// regions: x0,y0,x1,y1 (from the top)
let regions: [(String, Int, Int, Int, Int)] = [("all",0,0,1080,1920),("camera",170,1050,910,1430),("wall",200,1060,450,1250),("slide",0,290,1080,1010),("top",0,0,1080,280),("subtitle",0,1480,1080,1600)]
for (name,x0,y0,x1,y1) in regions { var s=[Double](repeating:0,count:3), t=[Double](repeating:0,count:3), d=0.0, n=0.0
  for y in y0..<y1 { for x in x0..<x1 { let i=(y*w+x)*4; for c in 0..<3 { s[c]+=Double(A[i+c]); t[c]+=Double(B[i+c]); d+=abs(Double(A[i+c])-Double(B[i+c])) }; n+=1 } }
  print(name, String(format:"A=(%.1f %.1f %.1f) B=(%.1f %.1f %.1f) MAE=%.2f", s[0]/n,s[1]/n,s[2]/n,t[0]/n,t[1]/n,t[2]/n,d/n/3)) }
