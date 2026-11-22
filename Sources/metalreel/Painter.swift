// Painter: paints one frame from a display list (boxes, gradients, shadows, images, video frames,
// text lines, prerendered fallback bitmaps) with Core Image on Metal.
// Text is laid out and drawn with Core Text; video frames are decoded in hardware via AVAssetReader.
// HLG -> SDR tone mapping uses a 3D LUT that reproduces ffmpeg's zscale+hable chain.
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import CoreText
import ImageIO
import AVFoundation

let SRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// -- CSS value parsing ---------------------------------------------------------
struct RGBA { var r, g, b, a: Double }
func cssColor(_ s: String?) -> RGBA? {
	guard let s, let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") else { return nil }
	let n = s[s.index(after: open)..<close].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
	guard n.count >= 3 else { return nil }
	return RGBA(r: n[0] / 255, g: n[1] / 255, b: n[2] / 255, a: n.count > 3 ? n[3] : 1)
}
func cgColor(_ c: RGBA) -> CGColor { CGColor(colorSpace: SRGB, components: [c.r, c.g, c.b, c.a])! }
func ciColor(_ c: RGBA, _ extraAlpha: Double = 1) -> CIColor { CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * extraAlpha, colorSpace: SRGB)! }

/// Split on commas that are not inside parentheses
func splitTopLevelCommas(_ s: Substring) -> [String] {
	var out: [String] = [], cur = "", depth = 0
	for ch in s { if ch == "(" { depth += 1 }; if ch == ")" { depth -= 1 }; if ch == "," && depth == 0 { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(ch) } }
	if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur.trimmingCharacters(in: .whitespaces)) }
	return out
}
func cssLength(_ s: Substring, _ ref: Double) -> Double? {
	if s.hasSuffix("%") { return Double(s.dropLast()).map { $0 / 100 * ref } }
	if s.hasSuffix("px") { return Double(s.dropLast(2)) }
	return Double(s)
}

/// CSS linear/radial-gradient -> CGImage (w x h). Color stops may be % or px; a transparent stop takes its neighbor's color (like premultiplied interpolation).
func gradientImage(_ css: String, _ w: Int, _ h: Int) -> CGImage? {
	guard let open = css.firstIndex(of: "("), w > 0, h > 0 else { return nil }
	let kind = css[..<open]
	let parts = splitTopLevelCommas(css[css.index(after: open)..<css.index(before: css.endIndex)])
	var first = parts.first ?? ""
	var stops = parts
	if !(first.hasPrefix("rgb") || first.hasPrefix("#")) { stops.removeFirst() } else { first = "" }
	let W = Double(w), H = Double(h)
	let radial = kind.hasSuffix("radial-gradient")
	let conic = kind.hasSuffix("conic-gradient")
	// geometry: linear angle + line length / radial center + radii
	var angle = 180.0, cx = W / 2, cy = H / 2, rx = 0.0, ry = 0.0
	if radial {
		let p = first.split(separator: " ")
		let at = p.firstIndex(of: "at")
		if let at {
			if at + 1 < p.count { cx = cssLength(p[at + 1], W) ?? cx }
			if at + 2 < p.count { cy = cssLength(p[at + 2], H) ?? cy }
		}
		let sizes = p[..<(at ?? p.count)].filter { cssLength($0, 0) != nil }
		if sizes.count >= 2 { rx = cssLength(sizes[0], W)!; ry = cssLength(sizes[1], H)! } else if sizes.count == 1 { rx = cssLength(sizes[0], W)!; ry = rx }
		if rx == 0 { // CSS size keywords (default: farthest-corner); a circle uses one radius
			let circle = p.contains("circle")
			let fx = max(cx, W - cx), fy = max(cy, H - cy), nx = min(cx, W - cx), ny = min(cy, H - cy)
			if p.contains("closest-side") { rx = nx; ry = ny; if circle { rx = min(nx, ny); ry = rx } }
			else if p.contains("farthest-side") { rx = fx; ry = fy; if circle { rx = max(fx, fy); ry = rx } }
			else if p.contains("closest-corner") { if circle { rx = (nx * nx + ny * ny).squareRoot(); ry = rx } else { rx = nx * 2.0.squareRoot(); ry = ny * 2.0.squareRoot() } }
			else if circle { rx = (fx * fx + fy * fy).squareRoot(); ry = rx }
			else { rx = fx * 2.0.squareRoot(); ry = fy * 2.0.squareRoot() }
		}
	} else if conic {
		let p = first.split(separator: " ").map(String.init)
		if let fi = p.firstIndex(of: "from"), fi + 1 < p.count { angle = p[fi + 1].hasSuffix("turn") ? (Double(p[fi + 1].dropLast(4)) ?? 0) * 360 : p[fi + 1].hasSuffix("rad") ? (Double(p[fi + 1].dropLast(3)) ?? 0) * 180 / .pi : Double(p[fi + 1].replacingOccurrences(of: "deg", with: "")) ?? 0 } else { angle = 0 }
		if let at = p.firstIndex(of: "at") { if at + 1 < p.count { cx = cssLength(Substring(p[at + 1]), W) ?? cx }; if at + 2 < p.count { cy = cssLength(Substring(p[at + 2]), H) ?? cy } }
	} else {
		if first.hasSuffix("deg") { angle = Double(first.dropLast(3)) ?? 180 }
		else if first.hasPrefix("to ") { angle = ["to top": 0, "to right": 90, "to bottom": 180, "to left": 270][first] ?? 180 }
	}
	let t = angle * .pi / 180
	let L = radial ? rx : conic ? 360 : abs(W * sin(t)) + abs(H * cos(t))
	var colors: [RGBA] = [], positions: [Double?] = []
	for d in stops {
		guard let z = d.lastIndex(of: ")"), let c = cssColor(String(d[...z])) else { continue }
		colors.append(c)
		let rest = d[d.index(after: z)...].trimmingCharacters(in: .whitespaces)
		if rest.hasSuffix("%") { positions.append(Double(rest.dropLast()).map { $0 / 100 }) }
		else if rest.hasSuffix("px") { positions.append(Double(rest.dropLast(2)).map { L > 0 ? $0 / L : 0 }) }
		else if rest.hasSuffix("deg") { positions.append(Double(rest.dropLast(3)).map { $0 / 360 }) }
		else { positions.append(nil) }
	}
	guard colors.count >= 2 else { return nil }
	// missing positions: distribute evenly between the nearest known neighbors (CSS rule)
	var loc = positions
	if loc[0] == nil { loc[0] = 0 }
	if loc[loc.count - 1] == nil { loc[loc.count - 1] = max(1, loc.compactMap { $0 }.max() ?? 1) }
	var i = 1
	while i < loc.count {
		if loc[i] == nil {
			var j = i; while loc[j] == nil { j += 1 }
			let a0 = loc[i - 1]!, b0 = loc[j]!
			for k in i..<j { loc[k] = a0 + (b0 - a0) * Double(k - i + 1) / Double(j - i + 1) }
			i = j
		}
		i += 1
	}
	var resolved = loc.map { $0! }
	for k in 1..<resolved.count where resolved[k] < resolved[k - 1] { resolved[k] = resolved[k - 1] }
	for k in colors.indices where colors[k].a == 0 { // equivalent of premultiplied interpolation
		let neighbor = k > 0 ? colors[k - 1] : colors[min(k + 1, colors.count - 1)]
		colors[k] = RGBA(r: neighbor.r, g: neighbor.g, b: neighbor.b, a: 0)
	}
	// CGGradient does not accept locations outside 0...1: rescale when the last stops exceed 1
	let maxStop = max(1, resolved.last!)
	let g = CGGradient(colorsSpace: SRGB, colors: colors.map(cgColor) as CFArray, locations: resolved.map { CGFloat(min(1, $0 / maxStop)) })!
	let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: SRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	if conic {
		// CSS conic: clockwise from 12 o'clock, starting at `from`. Rasterized on the CPU once (cached by the caller).
		let stops = resolved.map { $0 / maxStop }
		var px = [UInt8](repeating: 0, count: w * h * 4)
		for y in 0..<h { for x in 0..<w {
			var a = atan2(Double(x) + 0.5 - cx, -(Double(y) + 0.5 - cy)) * 180 / .pi - angle
			a = (a.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
			var k = 0; while k + 1 < stops.count && stops[k + 1] < a { k += 1 }
			let c0 = colors[k], c1 = colors[min(k + 1, colors.count - 1)]
			let span = k + 1 < stops.count ? stops[k + 1] - stops[k] : 1
			let f = a <= stops[0] ? 0 : k + 1 >= stops.count ? 0 : max(0, min(1, (a - stops[k]) / max(span, 1e-9)))
			let r = c0.r + (c1.r - c0.r) * f, gg = c0.g + (c1.g - c0.g) * f, b = c0.b + (c1.b - c0.b) * f, al = c0.a + (c1.a - c0.a) * f
			let i = ((h - 1 - y) * w + x) * 4 // CGContext rows start at the bottom
			px[i] = UInt8(r * al * 255); px[i + 1] = UInt8(gg * al * 255); px[i + 2] = UInt8(b * al * 255); px[i + 3] = UInt8(al * 255)
		} }
		let data = CFDataCreate(nil, px, px.count)!
		return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: SRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
	} else if radial {
		c.translateBy(x: cx, y: H - cy); c.scaleBy(x: 1, y: ry / rx)
		c.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rx * maxStop, options: [.drawsAfterEndLocation])
	} else {
		let dx = sin(t) * L / 2, dy = cos(t) * L / 2 // CG y axis points up
		let startPt = CGPoint(x: W / 2 - dx, y: H / 2 - dy)
		let endPt = CGPoint(x: W / 2 - dx + 2 * dx * maxStop, y: H / 2 - dy + 2 * dy * maxStop)
		c.drawLinearGradient(g, start: startPt, end: endPt, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
	}
	return c.makeImage()
}

// -- Fonts: CSS family name -> font file --------------------------------------
final class FontRegistry {
	struct Family { let desc: CTFontDescriptor; let opsz: Double? }
	var families: [String: Family] = [:]
	var cache: [String: CTFont] = [:]
	init(directory: URL?) {
		// Optional folder of font files: every file is registered under its own family name.
		guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
		for url in files where ["ttf", "otf", "woff", "woff2", "ttc"].contains(url.pathExtension.lowercased()) {
			var e: Unmanaged<CFError>?; _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &e)
			for d in (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? [] {
				if let fam = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String, families[fam.lowercased()] == nil { families[fam.lowercased()] = Family(desc: d, opsz: nil) }
			}
		}
	}
	// Faces the page loaded (family -> faces); picked like Chrome does, by unicode-range + weight match
	struct Face { let id: Int; let desc: CTFontDescriptor; let wMin: Double; let wMax: Double; let italic: Bool; let ranges: [ClosedRange<UInt32>]; let variable: Bool }
	var faces: [String: [Face]] = [:]
	private var faceCounter = 0
	private var faceFonts: [String: CTFont] = [:]
	func add(_ f: [String: Any]) {
		guard let family = (f["family"] as? String)?.lowercased(), let path = f["path"] as? String else { return }
		let url = URL(fileURLWithPath: path) as CFURL
		guard let d = (CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor])?.first else {
			FileHandle.standardError.write("[warn] could not read font: \(path)\n".data(using: .utf8)!); return
		}
		let ws = ((f["w"] as? String) ?? "normal").split(separator: " ").map { $0 == "normal" ? 400.0 : $0 == "bold" ? 700.0 : Double($0) ?? 400 }
		var ranges: [ClosedRange<UInt32>] = []
		for p in ((f["u"] as? String) ?? "").split(separator: ",") {
			let t = p.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "U+", with: "")
			if t.isEmpty { continue }
			if t.contains("?") { let a = UInt32(t.replacingOccurrences(of: "?", with: "0"), radix: 16) ?? 0, b = UInt32(t.replacingOccurrences(of: "?", with: "F"), radix: 16) ?? 0; ranges.append(a...b) }
			else if let dash = t.firstIndex(of: "-") { if let a = UInt32(t[..<dash], radix: 16), let b = UInt32(t[t.index(after: dash)...], radix: 16) { ranges.append(a...b) } }
			else if let a = UInt32(t, radix: 16) { ranges.append(a...a) }
		}
		let probe = CTFontCreateWithFontDescriptor(d, 12, nil)
		let hasWeightAxis = ((CTFontCopyVariationAxes(probe) as? [[String: Any]]) ?? []).contains { ($0[kCTFontVariationAxisIdentifierKey as String] as? Int) == 0x77676874 }
		faceCounter += 1
		faces[family, default: []].append(Face(id: faceCounter, desc: d, wMin: ws.first ?? 400, wMax: ws.last ?? 400, italic: ((f["s"] as? String) ?? "") == "italic", ranges: ranges, variable: hasWeightAxis))
	}
	private func pickFace(_ family: String, _ w: Double, _ italic: Bool, _ u: UInt32) -> Face? {
		guard let fs = faces[family] else { return nil }
		let styled = fs.filter { $0.italic == italic }.isEmpty ? fs : fs.filter { $0.italic == italic }
		let distance = { (y: Face) -> Double in w < y.wMin ? y.wMin - w : (w > y.wMax ? w - y.wMax : 0) }
		let best = styled.map(distance).min() ?? 0
		return styled.first { distance($0) == best && ($0.ranges.isEmpty || $0.ranges.contains { $0.contains(u) }) }
	}
	private func ctFont(_ y: Face, _ w: Double, _ size: Double) -> CTFont {
		let k = "\(y.id)|\(w)|\(size)"
		if let f = faceFonts[k] { return f }
		let d = y.variable ? CTFontDescriptorCreateCopyWithVariation(y.desc, 0x77676874 as CFNumber, min(max(w, y.wMin), y.wMax)) : y.desc
		let f = CTFontCreateWithFontDescriptor(d, size, nil); faceFonts[k] = f; return f
	}
	/// Like Chrome: pick a face per character from the family list + unicode-range, and group runs of the same font
	func attributed(_ s: String, _ ff: String, _ w: Double, _ size: Double, _ italic: Bool, _ color: CGColor, _ ls: Double) -> (NSAttributedString, CTFont) {
		let familyList = ff.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased() }
		let m = NSMutableAttributedString()
		var primary: CTFont?
		var previousFont: CTFont?
		var run = ""
		func flush() {
			guard !run.isEmpty, let f = previousFont else { return }
			var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
			if ls != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = ls }
			m.append(NSAttributedString(string: run, attributes: attrs)); run = ""
		}
		for ch in s.unicodeScalars {
			var f: CTFont? = nil
			for a in familyList { if let y = pickFace(a, w, italic, ch.value) { f = ctFont(y, w, size); break } }
			if f == nil { f = previousFont ?? font(ff, w, size) } // combining marks stay in the previous run; otherwise fall back to the legacy table / system font
			if primary == nil { primary = f }
			if let o = previousFont, o !== f! { flush() }
			previousFont = f; run.unicodeScalars.append(ch)
		}
		flush()
		return (m, primary ?? font(ff, w, size))
	}

	func font(_ ff: String, _ w: Double, _ size: Double) -> CTFont {
		let key = "\(ff)|\(w)|\(size)"
		if let f = cache[key] { return f }
		let name = ff.split(separator: ",").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased() } ?? ""
		let f: CTFont
		if let a = families[name] {
			var d = CTFontDescriptorCreateCopyWithVariation(a.desc, 0x77676874 as CFNumber, w)
			if let o = a.opsz {
				d = CTFontDescriptorCreateCopyWithAttributes(d, [kCTFontOpticalSizeAttribute: "none"] as CFDictionary)
				d = CTFontDescriptorCreateCopyWithVariation(d, 0x6F70737A as CFNumber, o)
			}
			f = CTFontCreateWithFontDescriptor(d, size, nil)
		} else {
			// installed system font: pick the face of this family closest to the CSS weight (like Chrome's font matching)
			f = FontRegistry.systemFont(name, w, size)
		}
		cache[key] = f
		return f
	}

	private nonisolated(unsafe) static var systemFaces: [String: [(CTFontDescriptor, Double, Bool)]] = [:]
	private nonisolated(unsafe) static var warned = Set<String>()
	static func cssWeight(_ ct: Double) -> Double { // CT weight trait (-1…1) → CSS weight
		let t: [(Double, Double)] = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900)]
		return t.min { abs($0.0 - ct) < abs($1.0 - ct) }!.1
	}
	static func systemFont(_ family: String, _ w: Double, _ size: Double) -> CTFont {
		let real = family.hasPrefix(".") ? family : family
		if real.lowercased() == ".applesystemuifont" {
			let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
			return CTFontCreateCopyWithAttributes(base, size, nil, CTFontDescriptorCreateCopyWithVariation(CTFontCopyFontDescriptor(base), 0x77676874 as CFNumber, w))
		}
		let faces = systemFaces[real] ?? {
			let d = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: real] as CFDictionary)
			let all = (CTFontDescriptorCreateMatchingFontDescriptors(d, nil) as? [CTFontDescriptor]) ?? []
			let list = all.map { fd -> (CTFontDescriptor, Double, Bool) in
				let tr = CTFontDescriptorCopyAttribute(fd, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
				let wt = (tr[kCTFontWeightTrait] as? Double) ?? 0, sym = (tr[kCTFontSymbolicTrait] as? UInt32) ?? 0
				return (fd, cssWeight(wt), sym & CTFontSymbolicTraits.traitItalic.rawValue != 0)
			}
			systemFaces[real] = list; return list
		}()
		let upright = faces.filter { !$0.2 }
		if let best = (upright.isEmpty ? faces : upright).min(by: { abs($0.1 - w) < abs($1.1 - w) || (abs($0.1 - w) == abs($1.1 - w) && $0.1 > $1.1) }) {
			return CTFontCreateWithFontDescriptor(best.0, size, nil)
		}
		if !warned.contains(real) { warned.insert(real); FileHandle.standardError.write("  [warn] font '\(real)' not found; using the system default\n".data(using: .utf8)!) }
		return CTFontCreateWithName("Times" as CFString, size, nil)
	}
}

// -- Video sources ------------------------------------------------------------
nonisolated(unsafe) var emptySampleCount = 0
final class Prefetcher {
	private var queue: [CMSampleBuffer] = []
	private var finished = false, cancelled = false
	private let lock = NSCondition()
	init(_ o: AVAssetReaderTrackOutput, capacity: Int = 6) {
		Thread.detachNewThread { [self] in
			while let s = o.copyNextSampleBuffer() {
				if CMSampleBufferGetImageBuffer(s) == nil { emptySampleCount += 1; if emptySampleCount <= 20 { FileHandle.standardError.write("[video] sample without image buffer pts=\(s.presentationTimeStamp.seconds)\n".data(using: .utf8)!) }; continue }
				lock.lock()
				while queue.count >= capacity && !cancelled { lock.wait() }
				if cancelled { lock.unlock(); break }
				queue.append(s); lock.broadcast(); lock.unlock()
			}
			lock.lock(); finished = true; lock.broadcast(); lock.unlock()
		}
	}
	func take() -> CMSampleBuffer? {
		lock.lock(); defer { lock.unlock() }
		while queue.isEmpty && !finished { lock.wait() }
		if queue.isEmpty { return nil }
		let s = queue.removeFirst(); lock.broadcast(); return s
	}
	func stop() { lock.lock(); cancelled = true; lock.broadcast(); lock.unlock() }
}

final class VideoSource {
	let asset: AVURLAsset, track: AVAssetTrack, fps: Double, hlg: Bool, duration: Double
	var reopenCount = 0
	var reader: AVAssetReader?, prefetcher: Prefetcher?
	var cur: CMSampleBuffer?, next: CMSampleBuffer?
	init(_ url: URL) {
		asset = AVURLAsset(url: url)
		track = asset.tracks(withMediaType: .video).first!
		fps = Double(track.nominalFrameRate > 0 ? track.nominalFrameRate : 30)
		duration = track.timeRange.end.seconds
		let fd = track.formatDescriptions.first as! CMFormatDescription
		let tf = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
		hlg = tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
	}
	private func openReader(_ t: Double) {
		prefetcher?.stop(); reader?.cancelReading()
		let r = try! AVAssetReader(asset: asset)
		let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
			kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
		])
		o.alwaysCopiesSampleData = false
		r.add(o)
		r.timeRange = CMTimeRange(start: CMTime(seconds: max(0, t - 1 / fps), preferredTimescale: 600), duration: .positiveInfinity)
		r.startReading()
		reader = r; prefetcher = Prefetcher(o); cur = nil; next = prefetcher!.take()
	}
	func frame(_ t: Double) -> CMSampleBuffer? {
		let limit = t + min(0.25 / fps, 0.0015) // like Remotion: the last frame whose timestamp is <= t (tiny slack for timebase rounding)
		if reader == nil || (cur.map { $0.presentationTimeStamp.seconds > limit } ?? false) || (next.map { limit - $0.presentationTimeStamp.seconds > 2 } ?? false) { openReader(t) }
		while let n = next, n.presentationTimeStamp.seconds <= limit { cur = n; next = prefetcher!.take() }
		// If the reader stopped before end of file (AVAssetReader can bail out on long reads), reopen it where it left off
		if next == nil, let c = cur, limit - c.presentationTimeStamp.seconds > 1.5 / fps, t < duration - 2 / fps {
			reopenCount += 1
			FileHandle.standardError.write("[video] reader stopped at \(c.presentationTimeStamp.seconds) s (status \(reader?.status.rawValue ?? -1), \(reader?.error?.localizedDescription ?? "no error")), reopening\n".data(using: .utf8)!)
			openReader(t)
			while let n = next, n.presentationTimeStamp.seconds <= limit { cur = n; next = prefetcher!.take() }
		}
		return cur ?? next
	}
}

/// HLG chain matching Remotion OffthreadVideo (toneMapped): arib-std-b67 -> linear x10 -> BT.709 primaries -> hable (peak 10) -> BT.709 OETF
let hlgLUT: Data = {
	let n = 64
	var d = [Float](repeating: 0, count: n * n * n * 4)
	func inv(_ e: Double) -> Double { e <= 0.5 ? e * e / 3 : (exp((e - 0.55991073) / 0.17883277) + 0.28466892) / 12 }
	func hable(_ x: Double) -> Double { let a = 0.15, b = 0.5, c = 0.1, dd = 0.2, e = 0.02, f = 0.3; return (x * (x * a + b * c) + dd * e) / (x * (x * a + b) + dd * f) - e / f }
	func oetf(_ l: Double) -> Double { let x = min(1, max(0, l)); return x < 0.018 ? 4.5 * x : 1.099 * pow(x, 0.45) - 0.099 }
	let hp = hable(10); var i = 0
	for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
		let R = inv(Double(ri) / Double(n - 1)) * 10, G = inv(Double(gi) / Double(n - 1)) * 10, B = inv(Double(bi) / Double(n - 1)) * 10
		let r = 1.6605 * R - 0.5876 * G - 0.0728 * B, g = -0.1246 * R + 1.1329 * G - 0.0083 * B, b = -0.0182 * R - 0.1006 * G + 1.1187 * B
		let s = max(r, g, b, 1e-6), k = (hable(s) / hp) / s
		d[i] = Float(oetf(r * k)); d[i + 1] = Float(oetf(g * k)); d[i + 2] = Float(oetf(b * k)); d[i + 3] = 1; i += 4
	} } }
	return d.withUnsafeBufferPointer { Data(buffer: $0) }
}()

// -- Painter ------------------------------------------------------------------
final class Painter {
	let W: Double, H: Double
	let fonts: FontRegistry
	private var images: [String: CIImage] = [:]
	private var gradients: [String: CIImage] = [:]
	private var texts: [String: (CIImage, Int)] = [:]
	var videos: [String: VideoSource] = [:]
	var retained: [CMSampleBuffer] = [] // keep video frames alive until the GPU work finishes
	let cube = CIFilter.colorCube()

	init(width: Double, height: Double, fonts: FontRegistry) {
		self.W = width; self.H = height; self.fonts = fonts
		cube.cubeDimension = 64; cube.cubeData = hlgLUT
	}

	var ctx: CIContext?
	/// Render an image once into an IOSurface-backed pixel buffer: later frames neither re-decode nor re-upload it
	func persistent(_ img: CIImage) -> CIImage {
		guard let ctx, img.extent.width > 0, img.extent.height > 0, img.extent.width * img.extent.height <= 4096 * 4096 else { return img }
		let w = Int(img.extent.width.rounded(.up)), h = Int(img.extent.height.rounded(.up))
		var pb: CVPixelBuffer?
		CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](), kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
		guard let pb else { return img }
		ctx.render(img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY)), to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: SRGB)
		return CIImage(cvPixelBuffer: pb, options: [.colorSpace: SRGB]).transformed(by: CGAffineTransform(translationX: img.extent.minX, y: img.extent.minY))
	}

	@inline(__always) func rect(_ b: [Double]) -> CGRect { CGRect(x: b[0], y: H - b[1] - b[3], width: b[2], height: b[3]) }
	func rounded(_ r: CGRect, _ radius: Double, _ c: CIColor) -> CIImage {
		if radius < 0.25 { return CIImage(color: c).cropped(to: r) }
		let g = CIFilter.roundedRectangleGenerator(); g.extent = r; g.radius = Float(min(radius, min(r.width, r.height) / 2)); g.color = c
		return g.outputImage!
	}
	func clip(_ img: CIImage, _ r: CGRect, _ radius: Double) -> CIImage {
		if radius < 0.25 { return img.cropped(to: r) }
		let f = CIFilter.blendWithAlphaMask(); f.inputImage = img; f.backgroundImage = CIImage.empty()
		f.maskImage = rounded(r, radius, CIColor(red: 1, green: 1, blue: 1)); return f.outputImage!.cropped(to: r)
	}
	func finish(_ img: CIImage, _ op: [String: Any]) -> CIImage {
		var x = img
		for c in (op["c"] as? [[Double]]) ?? [] {
			if c.count >= 11 { // clip rect in an element's local space + its affine transform (rotated / skewed overflow:hidden)
				let local = CGRect(x: c[0], y: H - c[1] - c[3], width: c[2], height: c[3])
				let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
				let t = flip.concatenating(CGAffineTransform(a: c[5], b: c[6], c: c[7], d: c[8], tx: c[9], ty: c[10])).concatenating(flip)
				let mask = rounded(local, c[4], CIColor(red: 1, green: 1, blue: 1)).transformed(by: t)
				let f = CIFilter.blendWithAlphaMask(); f.inputImage = x; f.backgroundImage = CIImage.empty(); f.maskImage = mask
				x = f.outputImage!.cropped(to: mask.extent)
			} else { x = clip(x, rect(c), c[4]) }
		}
		let o = (op["o"] as? Double) ?? 1
		if o < 0.999 { let f = CIFilter.colorMatrix(); f.inputImage = x; f.aVector = CIVector(x: 0, y: 0, z: 0, w: o); x = f.outputImage! }
		return x
	}

	func box(_ op: [String: Any]) -> CIImage {
		let b = op["b"] as! [Double], r = rect(b), radius = (op["r"] as? Double) ?? 0
		var img = CIImage.empty()
		for g in ((op["sh"] as? [[String: Any]]) ?? []).reversed() where !((g["ic"] as? Bool) ?? false) {
			guard let c = cssColor(g["c"] as? String), c.a > 0 else { continue }
			let spread = g["s"] as! Double, blur = g["b"] as! Double
			var s = rounded(r.insetBy(dx: -spread, dy: -spread).offsetBy(dx: g["x"] as! Double, dy: -(g["y"] as! Double)), radius > 0 ? radius + spread : 0, ciColor(c))
			if blur > 0.5 { s = s.applyingGaussianBlur(sigma: blur / 2).cropped(to: r.insetBy(dx: -spread - blur * 2 - 40, dy: -spread - blur * 2 - 40).offsetBy(dx: g["x"] as! Double, dy: -(g["y"] as! Double))) }
			img = s.composited(over: img)
		}
		// background covers the border box (background-clip: border-box); the border ring is painted on top
		if let bg = cssColor(op["bg"] as? String) { img = rounded(r, radius, ciColor(bg)).composited(over: img) }
		var ring: CIImage? = nil
		if let bw = op["br"] as? [String: Any], let c = cssColor(bw["c"] as? String) {
			let w = bw["w"] as! Double
			let f = CIFilter.sourceOutCompositing(); f.inputImage = rounded(r, radius, ciColor(c))
			f.backgroundImage = rounded(r.insetBy(dx: w, dy: w), max(0, radius - w), CIColor(red: 1, green: 1, blue: 1)); ring = f.outputImage!
		}
		if let gi = op["gi"] as? String {
			let w = Int(b[2].rounded(.up)), h = Int(b[3].rounded(.up))
			let key = "\(gi)|\(w)|\(h)"
			// multiple background layers: the first one listed is on top
			let g = gradients[key] ?? {
				var i = CIImage.empty()
				for k in splitTopLevelCommas(Substring(gi)).reversed() { if let c = gradientImage(k, w, h) { i = CIImage(cgImage: c).composited(over: i) } }
				i = persistent(i); gradients[key] = i; return i
			}()
			img = clip(g.transformed(by: CGAffineTransform(translationX: r.minX, y: r.minY)), r, radius).composited(over: img)
		}
		// inner (inset) shadows: inside the box, above the background; the first one listed is on top
		for g in ((op["sh"] as? [[String: Any]]) ?? []).reversed() where (g["ic"] as? Bool) ?? false {
			guard let c = cssColor(g["c"] as? String), c.a > 0 else { continue }
			let spread = g["s"] as! Double, blur = g["b"] as! Double, dx = g["x"] as! Double, dy = g["y"] as! Double
			var hole = rounded(r.insetBy(dx: spread, dy: spread).offsetBy(dx: dx, dy: -dy), max(0, radius - spread), CIColor(red: 1, green: 1, blue: 1))
			if blur > 0.5 { hole = hole.applyingGaussianBlur(sigma: blur / 2) }
			let f = CIFilter.sourceOutCompositing(); f.inputImage = CIImage(color: ciColor(c)).cropped(to: r); f.backgroundImage = hole
			img = clip(f.outputImage!, r, radius).composited(over: img)
		}
		if let ring { img = ring.composited(over: img) }
		return img
	}

	func image(_ op: [String: Any]) -> CIImage? {
		let b = op["b"] as! [Double], r = rect(b)
		var src: CIImage
		if let v = op["v"] as? [String: Any], let path = v["src"] as? String, let t = v["time"] as? Double {
			let vs = videos[path] ?? { let k = VideoSource(URL(fileURLWithPath: path)); videos[path] = k; return k }()
			guard let sb = vs.frame(t), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
			retained.append(sb)
			if vs.hlg { cube.inputImage = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()]); src = cube.outputImage! }
			else { src = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()]) } // like Chrome/Remotion: matrix conversion, no color management
		} else if let path = op["src"] as? String {
			src = images[path] ?? {
				guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return .empty() }
				let i = persistent(CIImage(cgImage: cg)); images[path] = i; return i
			}()
		} else { return nil }
		let iw = src.extent.width, ih = src.extent.height
		guard iw > 0, ih > 0 else { return nil }
		var target = r
		switch op["fit"] as? String ?? "fill" {
		case "contain", "cover":
			let s = (op["fit"] as? String) == "contain" ? min(r.width / iw, r.height / ih) : max(r.width / iw, r.height / ih)
			target = CGRect(x: r.midX - iw * s / 2, y: r.midY - ih * s / 2, width: iw * s, height: ih * s)
		default: break
		}
		let t = CGAffineTransform(scaleX: target.width / iw, y: target.height / ih).concatenating(CGAffineTransform(translationX: target.minX, y: target.minY))
		let placed = src.clampedToExtent().transformed(by: t).cropped(to: target)
		return clip(placed, r, (op["r"] as? Double) ?? 0)
	}

	/// Chrome's line box height = rounded (ascent + descent). Among the font's hhea / OS2-typo / OS2-win metric sets,
	/// pick the one that fits the box and derive the baseline from it (for tall fonts such as Arabic, Core Text's metrics can differ from Chrome's).
	func chromeAscent(_ f: CTFont, _ h: Double) -> Double {
		let upm = Double(CTFontGetUnitsPerEm(f)), size = Double(CTFontGetSize(f))
		var candidates: [(Double, Double)] = [(Double(CTFontGetAscent(f)), Double(CTFontGetDescent(f)))]
		if let os2 = CTFontCopyTable(f, CTFontTableTag(kCTFontTableOS2), []) as Data?, os2.count >= 78 {
			func i16(_ o: Int) -> Double { Double(Int16(bitPattern: UInt16(os2[o]) << 8 | UInt16(os2[o + 1]))) }
			func u16(_ o: Int) -> Double { Double(UInt16(os2[o]) << 8 | UInt16(os2[o + 1])) }
			candidates.append((i16(68) / upm * size, -i16(70) / upm * size))
			candidates.append((u16(74) / upm * size, u16(76) / upm * size))
		}
		let r = candidates.map { ($0.0.rounded(), $0.1.rounded()) }
		// Use Core Text's (hhea) metrics if they fit the box; otherwise (e.g. Arabic fonts) the closest set
		let chosen = abs(r[0].0 + r[0].1 - h) <= 2.5 ? r[0] : r.min { abs($0.0 + $0.1 - h) < abs($1.0 + $1.1 - h) }!
		return (h - (chosen.0 + chosen.1)) / 2 + chosen.0
	}

	/// Place text into Chrome's line box (x, y, w, h) using Core Text
	func text(_ op: [String: Any]) -> CIImage? {
		let b = op["b"] as! [Double]
		let s = op["s"] as! String
		guard let col = cssColor(op["col"] as? String) else { return nil }
		let ls = (op["ls"] as? Double) ?? 0
		let fx = b[0] - b[0].rounded(.down), fy = b[1] - b[1].rounded(.down)
		let pad = Int(max(12, ((op["fs"] as? Double) ?? 16) * 0.8)) // don't clip diacritics / overflowing glyphs
		let key = "\(s)|\(op["ff"] ?? "")|\(op["fw"] ?? "")|\(op["fs"] ?? "")|\(op["col"] ?? "")|\(ls)|\(Int(fx * 8))|\(Int(fy * 8))|\(Int(b[3]))"
		let (img, ch) = texts[key] ?? {
			let (attrText, font) = fonts.attributed(s, op["ff"] as? String ?? "", (op["fw"] as? Double) ?? 400, (op["fs"] as? Double) ?? 16, ((op["fi"] as? Int) ?? 0) == 1, cgColor(col), ls)
			let line = CTLineCreateWithAttributedString(attrText)
			let lw = CTLineGetTypographicBounds(line, nil, nil, nil)
			let cw = Int((max(lw, b[2]) + fx).rounded(.up)) + pad * 2, ch = Int((b[3] + fy).rounded(.up)) + pad * 2
			let c = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0, space: SRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
			c.setShouldSmoothFonts(true); c.setAllowsFontSubpixelPositioning(true); c.setShouldSubpixelPositionFonts(true)
			let base = Double(pad) + fy + chromeAscent(font, b[3])
			c.textMatrix = .identity; c.textPosition = CGPoint(x: Double(pad) + fx, y: Double(ch) - base)
			CTLineDraw(line, c)
			let v = (CIImage(cgImage: c.makeImage()!), ch); texts[key] = v; return v
		}()
		if texts.count > 400 { texts.removeAll(keepingCapacity: true) }
		let x0 = b[0].rounded(.down) - Double(pad), yTop = b[1].rounded(.down) - Double(pad)
		var placed = img.transformed(by: CGAffineTransform(translationX: x0, y: H - yTop - Double(ch)))
		// text-shadow: color + blur + offset, drawn under the text (the first shadow is on top)
		var shadowImg = CIImage.empty()
		for g in ((op["ts"] as? [[String: Any]]) ?? []).reversed() {
			guard let c = cssColor(g["c"] as? String), c.a > 0 else { continue }
			let f = CIFilter.colorMatrix(); f.inputImage = placed
			f.rVector = CIVector(x: 0, y: 0, z: 0, w: 0); f.gVector = CIVector(x: 0, y: 0, z: 0, w: 0); f.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
			f.aVector = CIVector(x: 0, y: 0, z: 0, w: c.a); f.biasVector = CIVector(x: c.r, y: c.g, z: c.b, w: 0)
			var sh = f.outputImage!
			let blur = g["b"] as? Double ?? 0
			if blur > 0.5 { sh = sh.applyingGaussianBlur(sigma: blur / 2) }
			shadowImg = sh.transformed(by: CGAffineTransform(translationX: g["x"] as? Double ?? 0, y: -(g["y"] as? Double ?? 0))).composited(over: shadowImg)
		}
		if op["ts"] != nil { placed = placed.composited(over: shadowImg) }
		return placed
	}

	private var pngs: [String: CIImage] = [:]
	/// An element Chrome rasterized on its own (SVG, filter, clip-path...): place it as is
	func prerendered(_ op: [String: Any]) -> CIImage? {
		guard let path = op["png"] as? String else { return nil }
		let img = pngs[path] ?? {
			guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return .empty() }
			let i = persistent(CIImage(cgImage: cg)); pngs[path] = i; return i
		}()
		if pngs.count > 300 { pngs.removeAll(keepingCapacity: true) }
		let b = op["b"] as! [Double]
		return img.transformed(by: CGAffineTransform(translationX: b[0], y: H - b[1] - img.extent.height))
	}

	/// CSS filter functions (Filter Effects spec matrices, in sRGB space, like Chrome's shorthand filters)
	func applyFilters(_ img: CIImage, _ list: [String]) -> CIImage {
		var x = img
		for f in list {
			guard let open = f.firstIndex(of: "(") else { continue }
			let name = String(f[..<open]); var arg = f[f.index(after: open)...].dropLast().trimmingCharacters(in: .whitespaces)
			var v: Double
			if arg.hasSuffix("%") { arg.removeLast(); v = (Double(arg) ?? 100) / 100 }
			else if arg.hasSuffix("deg") { v = Double(arg.dropLast(3)) ?? 0 }
			else if arg.hasSuffix("px") { v = Double(arg.dropLast(2)) ?? 0 }
			else { v = Double(arg) ?? 1 }
			var M: [Double]? = nil, bias = [0.0, 0, 0]
			switch name {
			case "blur": if v > 0.1 { x = x.applyingGaussianBlur(sigma: v) }
			case "brightness": M = [v, 0, 0, 0, v, 0, 0, 0, v]
			case "contrast": M = [v, 0, 0, 0, v, 0, 0, 0, v]; bias = [0.5 - 0.5 * v, 0.5 - 0.5 * v, 0.5 - 0.5 * v]
			case "saturate", "grayscale":
				let s = name == "saturate" ? v : 1 - min(1, v)
				M = [0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s]
			case "sepia":
				let a = 1 - min(1, v)
				M = [0.393 + 0.607 * a, 0.769 - 0.769 * a, 0.189 - 0.189 * a, 0.349 - 0.349 * a, 0.686 + 0.314 * a, 0.168 - 0.168 * a, 0.272 - 0.272 * a, 0.534 - 0.534 * a, 0.131 + 0.869 * a]
			case "hue-rotate":
				let c = cos(v * .pi / 180), s = sin(v * .pi / 180)
				M = [0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928,
				     0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283,
				     0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072]
			case "invert": M = [1 - 2 * v, 0, 0, 0, 1 - 2 * v, 0, 0, 0, 1 - 2 * v]; bias = [v, v, v]
			case "opacity": let fm = CIFilter.colorMatrix(); fm.inputImage = x; fm.aVector = CIVector(x: 0, y: 0, z: 0, w: v); x = fm.outputImage!
			default: break
			}
			if let M {
				let fm = CIFilter.colorMatrix(); fm.inputImage = x
				fm.rVector = CIVector(x: M[0], y: M[1], z: M[2], w: 0); fm.gVector = CIVector(x: M[3], y: M[4], z: M[5], w: 0); fm.bVector = CIVector(x: M[6], y: M[7], z: M[8], w: 0)
				fm.biasVector = CIVector(x: bias[0], y: bias[1], z: bias[2], w: 0)
				x = fm.outputImage!.applyingFilter("CIColorClamp")
			}
		}
		return x
	}
	static let blendModes: [String: String] = ["multiply": "CIMultiplyBlendMode", "screen": "CIScreenBlendMode", "overlay": "CIOverlayBlendMode", "darken": "CIDarkenBlendMode",
		"lighten": "CILightenBlendMode", "color-dodge": "CIColorDodgeBlendMode", "color-burn": "CIColorBurnBlendMode", "hard-light": "CIHardLightBlendMode",
		"soft-light": "CISoftLightBlendMode", "difference": "CIDifferenceBlendMode", "exclusion": "CIExclusionBlendMode", "hue": "CIHueBlendMode",
		"saturation": "CISaturationBlendMode", "color": "CIColorBlendMode", "luminosity": "CILuminosityBlendMode", "plus-lighter": "CIAdditionCompositing"]
	func blend(_ top: CIImage, _ bottom: CIImage, _ op: [String: Any]) -> CIImage {
		if let bm = op["bm"] as? String, let name = Painter.blendModes[bm], let f = CIFilter(name: name) {
			f.setValue(top, forKey: kCIInputImageKey); f.setValue(bottom, forKey: kCIInputBackgroundImageKey)
			return f.outputImage ?? top.composited(over: bottom)
		}
		return top.composited(over: bottom)
	}

	func draw(_ op: [String: Any]) -> CIImage? {
		switch op["t"] as? String {
		case "r": return box(op)
		case "i": return image(op)
		case "x": return text(op)
		default: return nil
		}
	}

	/// Small boxes (particles, dots, badges): if the look is identical, draw once (with its filters), then only translate.
	/// Position and opacity are not part of the key; sub-pixel position is rounded to 1/4 pixel.
	/// Persisting costs a synchronous GPU render, so only looks that are expensive to build (shadow, gradient, border, filter)
	/// are sprites; a plain fill / rounded rect is drawn directly (e.g. waveform bars whose height changes every frame).
	private var sprites: [String: CIImage] = [:]
	func sprite(_ op: [String: Any]) -> CIImage? {
		guard (op["t"] as? String) == "r", let b = op["b"] as? [Double], b[2] * b[3] <= 320 * 320,
			op["sh"] != nil || op["gi"] != nil || op["br"] != nil || op["fl"] != nil else { return nil }
		let ix = b[0].rounded(.down), iy = b[1].rounded(.down)
		let fx = ((b[0] - ix) * 4).rounded() / 4, fy = ((b[1] - iy) * 4).rounded() / 4
		let q = { (v: Double) in (v * 4).rounded() / 4 } // size is quantized to 1/4 pixel too (so growing/shrinking particles don't flood the cache)
		var local = op; local["b"] = [fx, fy, q(b[2]), q(b[3])]; local["c"] = []; local["o"] = 1
		if let r = op["r"] as? Double { local["r"] = q(r) }
		var key = ""
		for k in ["b", "r", "bg", "gi", "sh", "br", "fl"] { if let v = local[k] { key += "\(k)=\(v);" } }
		let img = sprites[key] ?? {
			var i = box(local)
			if let fl = op["fl"] as? [String] { i = applyFilters(i, fl) }
			// the local box lives in H-based coordinates: (0, H-...); pin it with a margin for overflowing blur/shadow
			let e = i.extent.insetBy(dx: -2, dy: -2).integral
			let s = persistent(i.cropped(to: e))
			if sprites.count > 2000 { sprites.removeAll() }
			sprites[key] = s; return s
		}()
		return img.transformed(by: CGAffineTransform(translationX: ix, y: -iy))
	}

	func frame(_ ops: [[String: Any]]) -> CIImage {
		var img = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
		// Consecutive layers with the same blend mode are merged among themselves first, then blended onto the backdrop once
		// (in CSS the inside of an element with mix-blend-mode is isolated and composited the same way; hundreds of particles = one blend).
		var group: CIImage? = nil, groupBM: String? = nil
		func finishGroup() {
			if let g = group { img = blend(g, img, ["bm": groupBM as Any]) }
			group = nil; groupBM = nil
		}
		func put(_ layer: CIImage, _ op: [String: Any]) {
			if let bm = op["bm"] as? String, Painter.blendModes[bm] != nil {
				if groupBM != bm { finishGroup(); groupBM = bm }
				group = group.map { layer.composited(over: $0) } ?? layer
			} else { finishGroup(); img = layer.composited(over: img) }
		}
		for op in ops {
			var layer: CIImage?
			if (op["t"] as? String) == "g" { if var h = prerendered(op) { if let fl = op["fl"] as? [String] { h = applyFilters(h, fl) }; put(finish(h, op), op) }; continue }
			if let m = op["m"] as? [Double], let lb = op["lb"] as? [Double] {
				// rotated element: draw in a local box (center = (0, H)), apply the linear transform, move to the bounding box center
				var local = op; local["b"] = [-lb[0] / 2, -lb[1] / 2, lb[0], lb[1]]
				let b = op["b"] as! [Double]
				let T = CGAffineTransform(translationX: 0, y: -H)
					.concatenating(CGAffineTransform(a: m[0], b: -m[1], c: -m[2], d: m[3], tx: 0, ty: 0))
					.concatenating(CGAffineTransform(translationX: b[0] + b[2] / 2, y: H - b[1] - b[3] / 2))
				layer = draw(local)?.transformed(by: T)
			} else {
				// backdrop-filter: filter what has been drawn so far, clip to the element's box, put it underneath
				if let bf = op["bf"] as? [String], let b = op["b"] as? [Double] {
					finishGroup()
					let r = rect(b)
					var backdrop = applyFilters(img.clampedToExtent(), bf)
					backdrop = finish(clip(backdrop, r, (op["r"] as? Double) ?? 0), op)
					img = backdrop.composited(over: img)
				}
				if let k = sprite(op) { put(finish(k, op), op); continue }
				layer = draw(op)
			}
			if var layer {
				if let fl = op["fl"] as? [String] { layer = applyFilters(layer, fl) }
				put(finish(layer, op), op)
			}
		}
		finishGroup()
		return img.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
	}
}
