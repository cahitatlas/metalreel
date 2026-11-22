// CSS value parsing for the native front end.
//
// React gives us *specified* values ("#f00", "50%", "translateX(20px) scale(1.2)", "2em").
// Chrome's display list (hybrid mode) carries *computed* values ("rgb(255, 0, 0)", px).
// The Painter speaks the computed dialect, so this file normalizes specified values into it.
import Foundation
import CoreGraphics

enum CSS {
	// MARK: colors
	static func color(_ raw: String?, current: String? = nil) -> RGBA? {
		guard var s = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
		if s.hasSuffix("!important") { s = String(s.dropLast(10)).trimmingCharacters(in: .whitespaces) }
		if s == "currentcolor" { return current.flatMap { color($0) } }
		if s == "transparent" { return RGBA(r: 0, g: 0, b: 0, a: 0) }
		if s.hasPrefix("#") {
			let h = Array(s.dropFirst())
			func hx(_ c: ArraySlice<Character>) -> Double { Double(Int(String(c), radix: 16) ?? 0) }
			switch h.count {
			case 3, 4: let v = h.map { hx([$0, $0][...]) / 255 }; return RGBA(r: v[0], g: v[1], b: v[2], a: h.count == 4 ? v[3] : 1)
			case 6, 8: return RGBA(r: hx(h[0...1]) / 255, g: hx(h[2...3]) / 255, b: hx(h[4...5]) / 255, a: h.count == 8 ? hx(h[6...7]) / 255 : 1)
			default: return nil
			}
		}
		if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
			let fn = s[..<open]
			let body = s[s.index(after: open)..<s.index(before: s.endIndex)]
			let parts = body.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
			func num(_ p: String, _ scale: Double) -> Double { p.hasSuffix("%") ? (Double(p.dropLast()) ?? 0) / 100 * scale : Double(p) ?? 0 }
			func alpha(_ i: Int) -> Double { parts.count > i ? num(parts[i], 1) : 1 }
			switch fn {
			case "rgb", "rgba":
				guard parts.count >= 3 else { return nil }
				return RGBA(r: num(parts[0], 255) / 255, g: num(parts[1], 255) / 255, b: num(parts[2], 255) / 255, a: alpha(3))
			case "hsl", "hsla":
				guard parts.count >= 3 else { return nil }
				var hue = Double(parts[0].replacingOccurrences(of: "deg", with: "")) ?? 0
				if parts[0].hasSuffix("turn") { hue = (Double(parts[0].dropLast(4)) ?? 0) * 360 }
				let sat = num(parts[1].hasSuffix("%") ? parts[1] : parts[1] + "%", 1), lig = num(parts[2].hasSuffix("%") ? parts[2] : parts[2] + "%", 1)
				let (r, g, b) = hslToRgb(hue, sat, lig)
				return RGBA(r: r, g: g, b: b, a: alpha(3))
			default: return nil
			}
		}
		if let n = named[s] { return RGBA(r: Double((n >> 16) & 255) / 255, g: Double((n >> 8) & 255) / 255, b: Double(n & 255) / 255, a: 1) }
		return nil
	}
	static func hslToRgb(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
		let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
		func f(_ n: Double) -> Double { let k = (n + hh * 12).truncatingRemainder(dividingBy: 12); let a = s * min(l, 1 - l); return l - a * max(-1, min(k - 3, 9 - k, 1)) }
		return (f(0), f(8), f(4))
	}
	/// Chrome's computed form: rgb(r, g, b) or rgba(r, g, b, a)
	static func computed(_ c: RGBA) -> String {
		let r = Int((c.r * 255).rounded()), g = Int((c.g * 255).rounded()), b = Int((c.b * 255).rounded())
		return c.a >= 1 ? "rgb(\(r), \(g), \(b))" : "rgba(\(r), \(g), \(b), \(fmt(c.a)))"
	}
	static func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%g", (d * 10000).rounded() / 10000) }

	// MARK: lengths
	struct Ctx { var fontSize: Double; var rootFontSize: Double = 16; var vw: Double; var vh: Double }
	enum Len: Equatable { case px(Double), percent(Double), auto, none }
	static func length(_ raw: String?, _ c: Ctx) -> Len? {
		guard var s = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
		if s.hasSuffix("!important") { s = String(s.dropLast(10)).trimmingCharacters(in: .whitespaces) }
		if s == "auto" { return .auto }
		if s == "none" { return .none }
		if s.hasSuffix("%") { return Double(s.dropLast()).map { .percent($0) } }
		if s.hasPrefix("calc(") { return calc(String(s.dropFirst(5).dropLast()), c) }
		return px(s, c).map { .px($0) }
	}
	static func px(_ s: String, _ c: Ctx) -> Double? {
		let units: [(String, Double)] = [("rem", c.rootFontSize), ("em", c.fontSize), ("px", 1), ("vw", c.vw / 100), ("vh", c.vh / 100), ("vmin", min(c.vw, c.vh) / 100), ("vmax", max(c.vw, c.vh) / 100), ("pt", 4.0 / 3), ("in", 96), ("cm", 96 / 2.54), ("mm", 96 / 25.4)]
		for (u, k) in units where s.hasSuffix(u) { return Double(s.dropLast(u.count)).map { $0 * k } }
		return Double(s)
	}
	/// calc() with + - * / over px and % (percent stays symbolic only if alone)
	static func calc(_ e: String, _ c: Ctx) -> Len? {
		let toks = e.replacingOccurrences(of: "(", with: " ( ").replacingOccurrences(of: ")", with: " ) ").split(separator: " ").map(String.init)
		var pct = 0.0, pxv = 0.0, sign = 1.0, mul: Double? = nil
		for t in toks {
			if t == "+" { sign = 1 } else if t == "-" { sign = -1 } else if t == "*" || t == "/" || t == "(" || t == ")" { continue }
			else if t.hasSuffix("%"), let v = Double(t.dropLast()) { pct += sign * v }
			else if let v = px(t, c) { if t.rangeOfCharacter(from: .letters) == nil, toks.contains("*") { mul = v } else { pxv += sign * v } }
		}
		if let m = mul { pxv *= m; pct *= m }
		if pct == 0 { return .px(pxv) }
		if pxv == 0 { return .percent(pct) }
		return .px(pxv + pct / 100 * c.vw) // rare; approximate against viewport width
	}
	static func resolve(_ l: Len?, _ ref: Double) -> Double? {
		switch l { case .px(let v): return v; case .percent(let p): return p / 100 * ref; default: return nil }
	}
	/// shorthand with 1–4 values (margin, padding, inset, border-width, border-radius parts)
	static func box4(_ raw: String?) -> [String]? {
		guard let raw, !raw.isEmpty else { return nil }
		let p = splitSpaces(raw)
		switch p.count { case 1: return [p[0], p[0], p[0], p[0]]; case 2: return [p[0], p[1], p[0], p[1]]; case 3: return [p[0], p[1], p[2], p[1]]; default: return Array(p.prefix(4)) }
	}
	/// split on whitespace outside parentheses
	static func splitSpaces(_ s: String) -> [String] {
		var out: [String] = [], cur = "", depth = 0
		for ch in s { if ch == "(" { depth += 1 }; if ch == ")" { depth -= 1 }
			if ch.isWhitespace && depth == 0 { if !cur.isEmpty { out.append(cur); cur = "" } } else { cur.append(ch) } }
		if !cur.isEmpty { out.append(cur) }
		return out
	}

	// MARK: transforms
	/// CSS transform list → affine matrix (CSS y-down coordinates, relative to the transform origin)
	static func transform(_ raw: String?, w: Double, h: Double, _ c: Ctx) -> CGAffineTransform? {
		guard let raw, !raw.isEmpty, raw != "none" else { return nil }
		var m = CGAffineTransform.identity
		var rest = Substring(raw)
		while let open = rest.firstIndex(of: "(") {
			guard let close = rest[open...].firstIndex(of: ")") else { break }
			let fn = rest[..<open].trimmingCharacters(in: .whitespaces).lowercased()
			let args = rest[rest.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0) }
			rest = rest[rest.index(after: close)...]
			func L(_ i: Int, _ ref: Double) -> Double { i < args.count ? (resolve(length(args[i], c), ref) ?? 0) : 0 }
			func A(_ i: Int) -> Double { i < args.count ? angle(args[i]) : 0 }
			func N(_ i: Int, _ d: Double) -> Double { i < args.count ? (args[i].hasSuffix("%") ? (Double(args[i].dropLast()) ?? 100) / 100 : Double(args[i]) ?? d) : d }
			var t = CGAffineTransform.identity
			switch fn {
			case "translate": t = CGAffineTransform(translationX: L(0, w), y: args.count > 1 ? L(1, h) : 0)
			case "translatex": t = CGAffineTransform(translationX: L(0, w), y: 0)
			case "translatey": t = CGAffineTransform(translationX: 0, y: L(0, h))
			case "translate3d": t = CGAffineTransform(translationX: L(0, w), y: L(1, h))
			case "translatez": t = .identity
			case "scale": let sx = N(0, 1); t = CGAffineTransform(scaleX: sx, y: args.count > 1 ? N(1, 1) : sx)
			case "scalex": t = CGAffineTransform(scaleX: N(0, 1), y: 1)
			case "scaley": t = CGAffineTransform(scaleX: 1, y: N(0, 1))
			case "scale3d": t = CGAffineTransform(scaleX: N(0, 1), y: N(1, 1))
			case "rotate", "rotatez": t = CGAffineTransform(rotationAngle: A(0))
			case "skew": t = CGAffineTransform(a: 1, b: tan(args.count > 1 ? A(1) : 0), c: tan(A(0)), d: 1, tx: 0, ty: 0)
			case "skewx": t = CGAffineTransform(a: 1, b: 0, c: tan(A(0)), d: 1, tx: 0, ty: 0)
			case "skewy": t = CGAffineTransform(a: 1, b: tan(A(0)), c: 0, d: 1, tx: 0, ty: 0)
			case "matrix": if args.count >= 6 { t = CGAffineTransform(a: N(0, 1), b: N(1, 0), c: N(2, 0), d: N(3, 1), tx: Double(args[4]) ?? 0, ty: Double(args[5]) ?? 0) }
			case "rotatex", "rotatey", "perspective", "rotate3d", "matrix3d": Diagnostics.warn("3D transform '\(fn)' approximated as 2D")
			default: Diagnostics.warn("unknown transform '\(fn)'")
			}
			m = t.concatenating(m) // CSS applies left-to-right: M = T1 · T2 · …
		}
		return m
	}
	static func angle(_ s: String) -> Double {
		if s.hasSuffix("deg") { return (Double(s.dropLast(3)) ?? 0) * .pi / 180 }
		if s.hasSuffix("grad") { return (Double(s.dropLast(4)) ?? 0) * .pi / 200 }
		if s.hasSuffix("rad") { return Double(s.dropLast(3)) ?? 0 }
		if s.hasSuffix("turn") { return (Double(s.dropLast(4)) ?? 0) * 2 * .pi }
		return (Double(s) ?? 0) * .pi / 180
	}
	static func origin(_ raw: String?, w: Double, h: Double, _ c: Ctx) -> (Double, Double) {
		guard let raw, !raw.isEmpty else { return (w / 2, h / 2) }
		var p = splitSpaces(raw.lowercased())
		if p.count == 1 { p.append(["top", "bottom"].contains(p[0]) ? p[0] : "center"); if ["top", "bottom"].contains(p[0]) { p = ["center", p[0]] } }
		if ["top", "bottom"].contains(p[0]) || ["left", "right"].contains(p[1]) { p.swapAt(0, 1) }
		func v(_ s: String, _ ref: Double) -> Double { switch s { case "left", "top": return 0; case "center": return ref / 2; case "right", "bottom": return ref; default: return resolve(length(s, c), ref) ?? ref / 2 } }
		return (v(p[0], w), v(p[1], h))
	}

	// MARK: shadows, gradients, filters (normalized to Chrome's computed dialect)
	static func shadows(_ raw: String?, _ c: Ctx, current: String?) -> [[String: Any]]? {
		guard let raw, !raw.isEmpty, raw != "none" else { return nil }
		var out: [[String: Any]] = []
		for part in splitTopLevelCommas(Substring(raw)) {
			var nums: [Double] = [], col: RGBA? = nil, inset = false
			for tok in splitSpaces(part) {
				if tok == "inset" { inset = true } else if let v = px(tok.lowercased(), c) { nums.append(v) } else if let cc = color(tok, current: current) { col = cc }
			}
			let cc = col ?? color(current) ?? RGBA(r: 0, g: 0, b: 0, a: 1)
			out.append(["c": computed(cc), "x": nums.count > 0 ? nums[0] : 0.0, "y": nums.count > 1 ? nums[1] : 0.0, "b": nums.count > 2 ? nums[2] : 0.0, "s": nums.count > 3 ? nums[3] : 0.0, "ic": inset])
		}
		return out.isEmpty ? nil : out
	}
	/// rewrites every color token inside gradient(s) to rgb()/rgba(); converts px stops with em etc.
	static func normalizeGradients(_ raw: String, _ c: Ctx, current: String?) -> String? {
		let layers = splitTopLevelCommas(Substring(raw)).filter { $0.contains("gradient(") }
		guard !layers.isEmpty else { return nil }
		return layers.map { layer -> String in
			guard let open = layer.firstIndex(of: "("), layer.hasSuffix(")") else { return layer }
			var kind = String(layer[..<open]).lowercased().trimmingCharacters(in: .whitespaces)
			if kind.hasPrefix("repeating-") { Diagnostics.warn("repeating gradients drawn as non-repeating"); kind = String(kind.dropFirst(10)) }
			let args = splitTopLevelCommas(layer[layer.index(after: open)..<layer.index(before: layer.endIndex)])
			let mapped = args.enumerated().map { (i, a) -> String in
				let toks = splitSpaces(a)
				if i == 0, toks.allSatisfy({ color($0) == nil }) {
					// geometry: keep, but normalize angle units to deg
					if kind == "linear-gradient", toks.count == 1, toks[0].rangeOfCharacter(from: .decimalDigits) != nil { return fmt(angle(toks[0]) * 180 / .pi) + "deg" }
					return toks.map { $0.lowercased() == "circle" || $0.lowercased() == "ellipse" ? $0 : ($0.lowercased().hasSuffix("em") ? (px($0.lowercased(), c).map { fmt($0) + "px" } ?? $0) : $0) }.joined(separator: " ")
				}
				return toks.map { t in color(t, current: current).map(computed) ?? (px(t.lowercased(), c).map { t.hasSuffix("%") ? t : fmt($0) + "px" } ?? t) }.joined(separator: " ")
			}
			// "transparent" etc are handled; Chrome also turns "to top right" into an angle – Painter maps the 4 sides
			return kind + "(" + mapped.joined(separator: ", ") + ")"
		}.joined(separator: ", ")
	}
	static func filters(_ raw: String?, _ c: Ctx) -> ([String], [String]) { // (native-paintable, unsupported)
		guard let raw, !raw.isEmpty, raw != "none" else { return ([], []) }
		var ok: [String] = [], bad: [String] = []
		var rest = Substring(raw)
		while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
			let fn = rest[..<open].trimmingCharacters(in: .whitespaces).lowercased(), arg = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
			rest = rest[rest.index(after: close)...]
			switch fn {
			case "blur": ok.append("blur(\(fmt(px(arg.lowercased(), c) ?? 0))px)")
			case "brightness", "contrast", "saturate", "grayscale", "sepia", "invert", "opacity":
				let v = arg.hasSuffix("%") ? (Double(arg.dropLast()) ?? 100) / 100 : (Double(arg) ?? 1); ok.append("\(fn)(\(fmt(v)))")
			case "hue-rotate": ok.append("hue-rotate(\(fmt(angle(arg) * 180 / .pi))deg)")
			default: bad.append(fn + "(" + arg + ")")
			}
		}
		return (ok, bad)
	}

	static let named: [String: Int] = [
		"aliceblue": 0xf0f8ff, "antiquewhite": 0xfaebd7, "aqua": 0x00ffff, "aquamarine": 0x7fffd4, "azure": 0xf0ffff, "beige": 0xf5f5dc, "bisque": 0xffe4c4, "black": 0x000000,
		"blanchedalmond": 0xffebcd, "blue": 0x0000ff, "blueviolet": 0x8a2be2, "brown": 0xa52a2a, "burlywood": 0xdeb887, "cadetblue": 0x5f9ea0, "chartreuse": 0x7fff00, "chocolate": 0xd2691e,
		"coral": 0xff7f50, "cornflowerblue": 0x6495ed, "cornsilk": 0xfff8dc, "crimson": 0xdc143c, "cyan": 0x00ffff, "darkblue": 0x00008b, "darkcyan": 0x008b8b, "darkgoldenrod": 0xb8860b,
		"darkgray": 0xa9a9a9, "darkgreen": 0x006400, "darkgrey": 0xa9a9a9, "darkkhaki": 0xbdb76b, "darkmagenta": 0x8b008b, "darkolivegreen": 0x556b2f, "darkorange": 0xff8c00, "darkorchid": 0x9932cc,
		"darkred": 0x8b0000, "darksalmon": 0xe9967a, "darkseagreen": 0x8fbc8f, "darkslateblue": 0x483d8b, "darkslategray": 0x2f4f4f, "darkslategrey": 0x2f4f4f, "darkturquoise": 0x00ced1, "darkviolet": 0x9400d3,
		"deeppink": 0xff1493, "deepskyblue": 0x00bfff, "dimgray": 0x696969, "dimgrey": 0x696969, "dodgerblue": 0x1e90ff, "firebrick": 0xb22222, "floralwhite": 0xfffaf0, "forestgreen": 0x228b22,
		"fuchsia": 0xff00ff, "gainsboro": 0xdcdcdc, "ghostwhite": 0xf8f8ff, "gold": 0xffd700, "goldenrod": 0xdaa520, "gray": 0x808080, "green": 0x008000, "greenyellow": 0xadff2f, "grey": 0x808080,
		"honeydew": 0xf0fff0, "hotpink": 0xff69b4, "indianred": 0xcd5c5c, "indigo": 0x4b0082, "ivory": 0xfffff0, "khaki": 0xf0e68c, "lavender": 0xe6e6fa, "lavenderblush": 0xfff0f5, "lawngreen": 0x7cfc00,
		"lemonchiffon": 0xfffacd, "lightblue": 0xadd8e6, "lightcoral": 0xf08080, "lightcyan": 0xe0ffff, "lightgoldenrodyellow": 0xfafad2, "lightgray": 0xd3d3d3, "lightgreen": 0x90ee90, "lightgrey": 0xd3d3d3,
		"lightpink": 0xffb6c1, "lightsalmon": 0xffa07a, "lightseagreen": 0x20b2aa, "lightskyblue": 0x87cefa, "lightslategray": 0x778899, "lightslategrey": 0x778899, "lightsteelblue": 0xb0c4de, "lightyellow": 0xffffe0,
		"lime": 0x00ff00, "limegreen": 0x32cd32, "linen": 0xfaf0e6, "magenta": 0xff00ff, "maroon": 0x800000, "mediumaquamarine": 0x66cdaa, "mediumblue": 0x0000cd, "mediumorchid": 0xba55d3,
		"mediumpurple": 0x9370db, "mediumseagreen": 0x3cb371, "mediumslateblue": 0x7b68ee, "mediumspringgreen": 0x00fa9a, "mediumturquoise": 0x48d1cc, "mediumvioletred": 0xc71585, "midnightblue": 0x191970,
		"mintcream": 0xf5fffa, "mistyrose": 0xffe4e1, "moccasin": 0xffe4b5, "navajowhite": 0xffdead, "navy": 0x000080, "oldlace": 0xfdf5e6, "olive": 0x808000, "olivedrab": 0x6b8e23, "orange": 0xffa500,
		"orangered": 0xff4500, "orchid": 0xda70d6, "palegoldenrod": 0xeee8aa, "palegreen": 0x98fb98, "paleturquoise": 0xafeeee, "palevioletred": 0xdb7093, "papayawhip": 0xffefd5, "peachpuff": 0xffdab9,
		"peru": 0xcd853f, "pink": 0xffc0cb, "plum": 0xdda0dd, "powderblue": 0xb0e0e6, "purple": 0x800080, "rebeccapurple": 0x663399, "red": 0xff0000, "rosybrown": 0xbc8f8f, "royalblue": 0x4169e1,
		"saddlebrown": 0x8b4513, "salmon": 0xfa8072, "sandybrown": 0xf4a460, "seagreen": 0x2e8b57, "seashell": 0xfff5ee, "sienna": 0xa0522d, "silver": 0xc0c0c0, "skyblue": 0x87ceeb, "slateblue": 0x6a5acd,
		"slategray": 0x708090, "slategrey": 0x708090, "snow": 0xfffafa, "springgreen": 0x00ff7f, "steelblue": 0x4682b4, "tan": 0xd2b48c, "teal": 0x008080, "thistle": 0xd8bfd8, "tomato": 0xff6347,
		"turquoise": 0x40e0d0, "violet": 0xee82ee, "wheat": 0xf5deb3, "white": 0xffffff, "whitesmoke": 0xf5f5f5, "yellow": 0xffff00, "yellowgreen": 0x9acd32,
	]
}

/// Collects "not supported natively" warnings, printed once with counts at the end.
enum Diagnostics {
	nonisolated(unsafe) static var counts: [String: Int] = [:]
	nonisolated(unsafe) static var order: [String] = []
	static func warn(_ s: String) { if counts[s] == nil { order.append(s) }; counts[s, default: 0] += 1 }
	static func report() { for s in order { FileHandle.standardError.write("  [warn] \(s) (\(counts[s]!)×)\n".data(using: .utf8)!) } }
}
