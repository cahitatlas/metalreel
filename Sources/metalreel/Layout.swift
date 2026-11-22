// Native front end: element tree (from JavaScriptCore) → Yoga layout → Core Text lines → display list.
//
// The display list is the same wire format the hybrid (Chrome) path produces, so both modes share one
// Painter. Coordinates are CSS pixels, y down, in composition space.
//
// What is native today: block/flex/absolute layout (Yoga, content-box/border-box), inline text with
// mixed styles and Chrome-like greedy line breaking (Core Text shaping), backgrounds, gradients,
// borders, radii, box/text shadows, opacity, 2D transforms with transform-origin, overflow clipping,
// filters (blur & color), blend modes, <img>, <OffthreadVideo>, basic grid (see `buildGrid`). Anything else (SVG, clip-path, mask,
// drop-shadow, canvas) is rendered by WebKit for that element only (see WebFallback.swift).
import Foundation
import CoreGraphics
import CoreText
import CYoga
import ImageIO

// MARK: - box tree

final class Box {
	let tag: String
	var style: [String: String]
	let attrs: [String: Any]
	var children: [Box] = []
	let text: String?          // text node
	let markup: String?        // serialized subtree for WebKit fallback (svg, canvas, innerHTML)
	weak var parent: Box?
	var cs = Computed()
	var node: YGNodeRef?
	var display = "block"
	var paragraph: Paragraph?  // inline formatting context owned by this box
	var intrinsic: CGSize?     // replaced elements
	var gridStretch = false    // grid item stretched to its row (align-self: normal/stretch with height auto)
	init(tag: String, style: [String: String], attrs: [String: Any], text: String?, markup: String?) {
		self.tag = tag; self.style = style; self.attrs = attrs; self.text = text; self.markup = markup
	}
	var isText: Bool { text != nil }
	subscript(_ k: String) -> String? { style[k].map { $0.hasSuffix("!important") ? String($0.dropLast(10)).trimmingCharacters(in: .whitespaces) : $0 } }
}

/// Inherited text properties
struct Computed {
	var fontFamily = "Times"
	var fontSize = 16.0
	var fontWeight = 400.0
	var italic = false
	var color = RGBA(r: 0, g: 0, b: 0, a: 1)
	var lineHeight: LineHeight = .normal
	var letterSpacing = 0.0
	var wordSpacing = 0.0
	var textAlign = "start"
	var whiteSpace = "normal"
	var textShadow: String? = nil
	var textTransform = "none"
	var visible = true
	var direction = "ltr"
	var overflowWrap = "normal"
	enum LineHeight { case normal, px(Double), factor(Double) }
}

// MARK: - front end

final class NativeFrontEnd {
	let W: Double, H: Double
	let fonts: FontRegistry
	let fallback: WebFallback?
	private let config: YGConfigRef
	private var videoSizes: [String: CGSize] = [:]
	private var imageSizes: [String: CGSize] = [:]
	var unsupported = Set<String>()
	private var faceRules: [String] = []
	/// register a font face the page loaded (FontFace / @font-face) for measuring, painting and the WebKit fallback
	func addFont(_ d: [String: Any]) {
		fonts.add(d)
		guard let fam = d["family"] as? String, let path = d["path"] as? String else { return }
		var r = "@font-face{font-family:\"\(fam)\";src:url(\"file://\(path)\");font-weight:\(d["w"] ?? "normal");font-style:\(d["s"] ?? "normal")"
		if let u = d["u"] as? String, !u.isEmpty { r += ";unicode-range:\(u)" }
		faceRules.append(r + "}")
	}

	init(width: Double, height: Double, fonts: FontRegistry, fallback: WebFallback?) {
		W = width; H = height; self.fonts = fonts; self.fallback = fallback
		config = YGConfigNew()
		YGConfigSetUseWebDefaults(config, true)
		YGConfigSetPointScaleFactor(config, 64) // Chrome's LayoutUnit is 1/64 px
	}

	/// tree JSON (from `__mr_snapshot`) → display list
	func displayList(_ json: String) -> [[String: Any]] {
		guard let any = try? JSONSerialization.jsonObject(with: Data(json.utf8)), let rootObj = any as? [String: Any] else { return [] }
		let root = build(rootObj, parent: nil)
		root.style["position"] = "relative"; root.style["width"] = "\(W)px"; root.style["height"] = "\(H)px"
		cascade(root, inherited: Computed(), parentDisplay: "block")
		let yroot = yoga(root, parentDisplay: "block")
		YGNodeCalculateLayout(yroot, Float(W), Float(H), .LTR)
		var ops: [[String: Any]] = []
		paint(root, parent: .identity, ctx: PaintCtx(), ops: &ops)
		YGNodeFreeRecursive(yroot)
		return ops.map { NativeFrontEnd.normalize($0) as! [String: Any] }
	}

	/// The Painter reads numbers as Double (the wire format is JSON); CGFloat/Float/Int from layout math are converted.
	static func normalize(_ v: Any) -> Any {
		switch v {
		case let d as [String: Any]: var o = d; for (k, x) in d where k != "fi" { o[k] = normalize(x) }; return o
		case let a as [Any]: return a.map(normalize)
		case let f as CGFloat: return Double(f)
		case let f as Float: return Double(f)
		case let i as Int: return Double(i)
		default: return v
		}
	}

	private func build(_ o: [String: Any], parent: Box?) -> Box {
		let b = Box(tag: (o["t"] as? String) ?? "div", style: (o["s"] as? [String: String]) ?? [:], attrs: (o["a"] as? [String: Any]) ?? [:], text: nil, markup: o["h"] as? String)
		b.parent = parent
		for c in (o["c"] as? [Any]) ?? [] {
			if let s = c as? String { let t = Box(tag: "#text", style: [:], attrs: [:], text: s, markup: nil); t.parent = b; b.children.append(t) }
			else if let d = c as? [String: Any] { b.children.append(build(d, parent: b)) }
		}
		return b
	}

	// MARK: cascade (inheritance + UA defaults)
	static let inlineTags: Set<String> = ["span", "a", "b", "strong", "i", "em", "small", "big", "sub", "sup", "u", "s", "mark", "code", "label", "abbr", "cite", "q", "time", "font", "br", "wbr", "img", "video", "svg", "canvas", "bdi", "bdo"]
	static let uaFont: [String: (Double, Double, Double)] = ["h1": (2, 700, 0.67), "h2": (1.5, 700, 0.83), "h3": (1.17, 700, 1), "h4": (1, 700, 1.33), "h5": (0.83, 700, 1.67), "h6": (0.67, 700, 2.33)]
	static func genericFamily(_ f: String) -> String {
		f.split(separator: ",").map { p -> String in
			let n = p.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")); let l = n.lowercased()
			switch l { case "serif": return "Times"; case "sans-serif": return "Helvetica"; case "monospace": return "Courier"; case "cursive": return "Apple Chancery"; case "fantasy": return "Papyrus"
			case "system-ui", "-apple-system", "blinkmacsystemfont", "ui-sans-serif": return ".AppleSystemUIFont"; case "ui-monospace": return "Menlo"; case "ui-serif": return "New York"
			default: return n.contains(" ") ? "\"\(n)\"" : n }
		}.joined(separator: ", ")
	}

	private func cascade(_ b: Box, inherited: Computed, parentDisplay: String) {
		if b.isText { b.cs = inherited; b.display = "inline"; return }
		var c = inherited
		let cx = CSS.Ctx(fontSize: inherited.fontSize, vw: W, vh: H)
		if let ua = NativeFrontEnd.uaFont[b.tag] {
			c.fontSize = inherited.fontSize * ua.0; c.fontWeight = ua.1
			if b["marginTop"] == nil && b["margin"] == nil { b.style["marginTop"] = "\(ua.2 * c.fontSize)px"; b.style["marginBottom"] = "\(ua.2 * c.fontSize)px" }
		}
		if b.tag == "p", b["marginTop"] == nil, b["margin"] == nil { b.style["marginTop"] = "\(c.fontSize)px"; b.style["marginBottom"] = "\(c.fontSize)px" }
		if b.tag == "b" || b.tag == "strong" { c.fontWeight = inherited.fontWeight >= 600 ? 900 : 700 }
		if b.tag == "i" || b.tag == "em" { c.italic = true }
		if b.tag == "small" { c.fontSize = inherited.fontSize / 1.2 }
		if let font = b["font"] { applyFontShorthand(font, &c, cx) }
		if let v = b["fontSize"] {
			switch v.lowercased() { case "smaller": c.fontSize = inherited.fontSize / 1.2; case "larger": c.fontSize = inherited.fontSize * 1.2
			default: if let px = CSS.resolve(CSS.length(v, cx), inherited.fontSize) { c.fontSize = px } }
		}
		let ex = CSS.Ctx(fontSize: c.fontSize, vw: W, vh: H)
		if let v = b["fontFamily"] { c.fontFamily = NativeFrontEnd.genericFamily(v) }
		if let v = b["fontWeight"] { c.fontWeight = v == "bold" ? 700 : v == "normal" ? 400 : v == "bolder" ? min(900, inherited.fontWeight + 300) : v == "lighter" ? max(100, inherited.fontWeight - 300) : Double(v) ?? c.fontWeight }
		if let v = b["fontStyle"] { c.italic = v == "italic" || v == "oblique" }
		if let v = b["color"], let col = CSS.color(v, current: CSS.computed(inherited.color)) { c.color = col }
		if let v = b["lineHeight"] {
			if v == "normal" { c.lineHeight = .normal } else if let n = Double(v) { c.lineHeight = .factor(n) }
			else if let px = CSS.resolve(CSS.length(v, ex), c.fontSize) { c.lineHeight = .px(px) }
		}
		if let v = b["letterSpacing"] { c.letterSpacing = v == "normal" ? 0 : (CSS.resolve(CSS.length(v, ex), c.fontSize) ?? 0) }
		if let v = b["wordSpacing"] { c.wordSpacing = v == "normal" ? 0 : (CSS.resolve(CSS.length(v, ex), c.fontSize) ?? 0) }
		if let v = b["textAlign"] { c.textAlign = v }
		if let v = b["whiteSpace"] { c.whiteSpace = v }
		if let v = b["textShadow"] { c.textShadow = v == "none" ? nil : v }
		if let v = b["textTransform"] { c.textTransform = v }
		if let v = b["visibility"] { c.visible = v != "hidden" && v != "collapse" }
		if let v = b["direction"] { c.direction = v }
		if let v = b["overflowWrap"] ?? b["wordWrap"] { c.overflowWrap = v }
		for k in ["textDecoration", "textDecorationLine", "WebkitTextStroke", "textStroke", "WebkitBackgroundClip", "backgroundClip", "columnCount"] where b[k] != nil && b[k] != "none" && b[k] != "initial" {
			Diagnostics.warn("CSS '\(k)' is not painted natively yet")
		}
		b.cs = c
		b.display = (b["display"] ?? (NativeFrontEnd.inlineTags.contains(b.tag) ? "inline" : "block")).lowercased()
		if b.display == "-webkit-box" || b.display == "-webkit-inline-box" { b.display = "flex" }
		// blockification: children of flex containers and absolutely positioned boxes are blocks
		if ["flex", "inline-flex", "grid", "inline-grid"].contains(parentDisplay) || ["absolute", "fixed"].contains(b["position"] ?? "") {
			if b.display == "inline" || b.display == "inline-block" { b.display = "block" }
			if b.display == "inline-flex" { b.display = "flex" }
		}
		if b.tag == "br" { b.display = "br" }
		if b.className.contains("__remotion_objectfitcontain"), b["objectFit"] == nil { b.style["objectFit"] = "contain" }
		for ch in b.children { cascade(ch, inherited: c, parentDisplay: b.display) }
	}
	private func applyFontShorthand(_ v: String, _ c: inout Computed, _ cx: CSS.Ctx) {
		var toks = CSS.splitSpaces(v)
		guard let sizeIdx = toks.firstIndex(where: { CSS.length($0.split(separator: "/").first.map(String.init), cx) != nil && $0.first?.isNumber == true }) else { return }
		for t in toks[..<sizeIdx] { if t == "italic" { c.italic = true } else if t == "bold" { c.fontWeight = 700 } else if let w = Double(t) { c.fontWeight = w } }
		let sz = toks[sizeIdx].split(separator: "/").map(String.init)
		if let px = CSS.resolve(CSS.length(sz[0], cx), c.fontSize) { c.fontSize = px }
		if sz.count > 1 { if let n = Double(sz[1]) { c.lineHeight = .factor(n) } else if let px = CSS.px(sz[1], cx) { c.lineHeight = .px(px) } }
		toks.removeFirst(sizeIdx + 1)
		if !toks.isEmpty { c.fontFamily = NativeFrontEnd.genericFamily(toks.joined(separator: " ")) }
	}

	// MARK: Yoga tree
	/// text, inline elements and <br>; replaced elements (img, video, svg, canvas) are laid out as atomic blocks
	private func isInlineContent(_ b: Box) -> Bool { b.isText || b.display == "br" || (b.display == "inline" && b.markup == nil && b.tag != "img" && b.tag != "video") }

	private var ydepth = 0
	private func yoga(_ b: Box, parentDisplay: String) -> YGNodeRef {
		ydepth += 1; defer { ydepth -= 1 }
		if ydepth > 80 { fatalError("layout tree too deep at <\(b.tag)> kids=\(b.children.map(\.tag))") }
		let n = YGNodeNewWithConfig(config)!
		b.node = n
		YGNodeSetContext(n, Unmanaged.passUnretained(b).toOpaque())
		applyStyle(b, n, parentDisplay: parentDisplay)
		if b.markup != nil || b.tag == "img" || b.tag == "video" {
			b.intrinsic = intrinsicSize(b)
			// intrinsic aspect ratio only matters when exactly one dimension is given (Yoga would otherwise let it override)
			let wAuto = [nil, "auto"].contains(b["width"]), hAuto = [nil, "auto"].contains(b["height"])
			if let s = b.intrinsic, s.width > 0, s.height > 0, b["aspectRatio"] == nil, wAuto != hAuto { YGNodeStyleSetAspectRatio(n, Float(s.width / s.height)) }
			YGNodeSetMeasureFunc(n, measureReplaced)
			return n
		}
		let kids = b.children.filter { !($0.isText && ($0.text ?? "").isEmpty) }
		if b.display == "grid" || b.display == "inline-grid", let cols = gridColumns(b) {
			buildGrid(b, n, kids, cols); return n
		}
		// a box whose content is only inline → it owns one paragraph and is measured as a leaf
		if !kids.isEmpty, kids.allSatisfy(isInlineContent), kids.contains(where: { $0.isText || $0.display == "inline" }) {
			if b.display == "flex" || b.display == "inline-flex" {
				// text directly in a flex container becomes one anonymous flex item per run of inline content
				let anon = Box(tag: "#anon", style: [:], attrs: [:], text: nil, markup: nil); anon.cs = b.cs; anon.display = "block"; anon.parent = b
				anon.children = kids; for k in kids { k.parent = anon }
				b.children = [anon]
				YGNodeInsertChild(n, yoga(anon, parentDisplay: b.display), 0)
				return n
			}
			b.paragraph = Paragraph(owner: b, fonts: fonts, ctx: CSS.Ctx(fontSize: b.cs.fontSize, vw: W, vh: H))
			if b.paragraph!.isEmpty { b.paragraph = nil } else { YGNodeSetMeasureFunc(n, measureParagraph); return n }
		}
		// mixed block + inline content: wrap inline runs in anonymous blocks
		var groups: [Box] = []; var pending: [Box] = []
		func flush() {
			guard !pending.isEmpty else { return }
			let hasText = pending.contains(where: { !$0.isText || !($0.text ?? "").allSatisfy(\.isWhitespace) || ["pre", "pre-wrap"].contains(b.cs.whiteSpace) })
			if hasText && b.tag == "#anon" && pending.count == kids.count { pending.removeAll(); return } // nothing paintable; avoid re-wrapping forever
			if hasText {
				let anon = Box(tag: "#anon", style: [:], attrs: [:], text: nil, markup: nil); anon.cs = b.cs; anon.display = "block"; anon.parent = b
				anon.children = pending; for k in pending { k.parent = anon }; groups.append(anon)
			}
			pending.removeAll()
		}
		// inline-level replaced elements (an inline <svg>/<img> in a block) sit on a line box: their bottom margin edge
		// on the baseline of the block's strut, so the line is the element plus the strut's descent below it (the
		// classic gap under an inline image; 4 px for the default 16px Times). Consecutive ones share one line.
		var line: [Box] = []
		func flushLine() {
			guard !line.isEmpty else { return }
			let (above, below) = Paragraph.strut(b.cs, fonts)
			let onBaseline = line.allSatisfy { ["baseline", nil].contains($0["verticalAlign"]) }
			let align = b.cs.textAlign, rtl = b.cs.direction == "rtl"
			let jc = ["center": "center", "-webkit-center": "center", "right": "flex-end", "-webkit-right": "flex-end", "end": rtl ? "flex-start" : "flex-end", "start": rtl ? "flex-end" : "flex-start"][align] ?? "flex-start"
			var st: [String: String] = ["flexDirection": "row", "alignItems": "flex-end", "justifyContent": jc, "minHeight": "\(above + below)px"]
			if onBaseline { st["paddingBottom"] = "\(below)px" } else { Diagnostics.warn("vertical-align on an inline replaced element approximated as bottom") }
			let anon = Box(tag: "#anon-line", style: st, attrs: [:], text: nil, markup: nil); anon.cs = b.cs; anon.display = "flex"; anon.parent = b
			anon.children = line; for k in line { k.parent = anon }; groups.append(anon)
			line.removeAll()
		}
		let blockContainer = !["flex", "inline-flex", "grid", "inline-grid"].contains(b.display) && b.tag != "#anon-line"
		func inlineReplaced(_ k: Box) -> Bool {
			// a percentage height would resolve against the line wrapper instead of the block; keep those as blocks
			blockContainer && (k.markup != nil || k.tag == "img" || k.tag == "video") && ["inline", "inline-block"].contains(k.display)
				&& !(k["height"]?.hasSuffix("%") ?? false) && !(k["position"].map { ["absolute", "fixed"].contains($0) } ?? false)
		}
		for k in kids {
			if inlineReplaced(k) { flush(); line.append(k); continue }
			if !line.isEmpty, k.isText, (k.text ?? "").allSatisfy(\.isWhitespace) { continue } // whitespace between icons
			flushLine()
			if isInlineContent(k) && !(k.display == "inline" && k.children.contains { !isInlineContent($0) }) { pending.append(k) } else { flush(); groups.append(k) }
		}
		flushLine()
		flush()
		b.children = groups
		for (i, k) in groups.enumerated() where k.display != "none" || true { YGNodeInsertChild(n, yoga(k, parentDisplay: b.display), Int(i)) }
		return n
	}

	private func applyStyle(_ b: Box, _ n: YGNodeRef, parentDisplay: String) {
		let cx = CSS.Ctx(fontSize: b.cs.fontSize, vw: W, vh: H)
		func L(_ k: String) -> CSS.Len? { b[k].flatMap { CSS.length($0, cx) } }
		let flexParent = ["flex", "inline-flex"].contains(parentDisplay) && b.parent?.tag != "#anon-line" // inline content never shrinks
		switch b.display {
		case "none": YGNodeStyleSetDisplay(n, .none)
		case "contents": YGNodeStyleSetDisplay(n, .contents)
		case "flex", "inline-flex": YGNodeStyleSetDisplay(n, .flex)
			let fd = b["flexDirection"] ?? (b["flexFlow"].flatMap { CSS.splitSpaces($0).first { ["row", "column", "row-reverse", "column-reverse"].contains($0) } }) ?? "row"
			YGNodeStyleSetFlexDirection(n, ["column": .column, "column-reverse": .columnReverse, "row-reverse": .rowReverse][fd] ?? .row)
			let wrap = b["flexWrap"] ?? (b["flexFlow"]?.contains("wrap") == true ? (b["flexFlow"]!.contains("wrap-reverse") ? "wrap-reverse" : "wrap") : "nowrap")
			YGNodeStyleSetFlexWrap(n, wrap == "wrap" ? .wrap : wrap == "wrap-reverse" ? .wrapReverse : .noWrap)
		case "grid", "inline-grid":
			YGNodeStyleSetFlexDirection(n, .column)
			if gridColumns(b) == nil { Diagnostics.warn("grid-template-columns '\(b["gridTemplateColumns"] ?? "")' not supported; grid approximated as a flex column") }
		default: // block-level boxes stack vertically and stretch horizontally
			YGNodeStyleSetFlexDirection(n, .column); YGNodeStyleSetAlignItems(n, .stretch)
		}
		if b.display == "inline-block" || b.display == "inline-flex" { Diagnostics.warn("inline-block/inline-flex laid out as block") }
		if let v = b["justifyContent"] { YGNodeStyleSetJustifyContent(n, ["center": .center, "flex-end": .flexEnd, "end": .flexEnd, "right": .flexEnd, "space-between": .spaceBetween, "space-around": .spaceAround, "space-evenly": .spaceEvenly][v] ?? .flexStart) }
		let alignMap: [String: YGAlign] = ["center": .center, "flex-start": .flexStart, "start": .flexStart, "self-start": .flexStart, "flex-end": .flexEnd, "end": .flexEnd, "self-end": .flexEnd, "stretch": .stretch, "normal": .stretch, "baseline": .baseline, "space-between": .spaceBetween, "space-around": .spaceAround, "space-evenly": .spaceEvenly]
		if let v = b["alignItems"] { YGNodeStyleSetAlignItems(n, alignMap[v] ?? .stretch) }
		if let v = b["alignSelf"], v != "auto", parentDisplay != "grid-cell" { YGNodeStyleSetAlignSelf(n, alignMap[v] ?? .auto) }
		if let v = b["alignContent"] { YGNodeStyleSetAlignContent(n, alignMap[v] ?? .stretch) }
		if let v = b["placeItems"] { let p = CSS.splitSpaces(v); YGNodeStyleSetAlignItems(n, alignMap[p[0]] ?? .stretch); if p.count > 1 || true { YGNodeStyleSetJustifyContent(n, ["center": .center, "end": .flexEnd, "flex-end": .flexEnd][p.last!] ?? .flexStart) } }
		// flex item properties
		var grow: Double? = nil, shrink: Double? = nil, basis: String? = nil
		if let f = b["flex"] {
			let p = CSS.splitSpaces(f)
			if f == "none" { grow = 0; shrink = 0; basis = "auto" } else if f == "auto" { grow = 1; shrink = 1; basis = "auto" }
			else { if let g = Double(p[0]) { grow = g; shrink = 1; basis = "0%" } else { basis = p[0] }
				if p.count > 1 { if let s = Double(p[1]) { shrink = s } else { basis = p[1] } }
				if p.count > 2 { basis = p[2] } }
		}
		if let v = b["flexGrow"].flatMap(Double.init) { grow = v }
		if let v = b["flexShrink"].flatMap(Double.init) { shrink = v }
		if let v = b["flexBasis"] { basis = v }
		if parentDisplay == "grid-cell" { grow = b.gridStretch ? 1 : 0; shrink = b.gridStretch ? 1 : 0; basis = "auto" } // flex properties don't apply to grid items
		YGNodeStyleSetFlexGrow(n, Float(grow ?? 0))
		YGNodeStyleSetFlexShrink(n, Float(shrink ?? (flexParent ? 1 : 0)))
		if let bs = basis { switch CSS.length(bs, cx) { case .px(let v): YGNodeStyleSetFlexBasis(n, Float(v)); case .percent(let p): YGNodeStyleSetFlexBasisPercent(n, Float(p)); default: YGNodeStyleSetFlexBasisAuto(n) } }
		// position
		let pos = b["position"] ?? "static"
		YGNodeStyleSetPositionType(n, pos == "absolute" || pos == "fixed" ? .absolute : pos == "static" ? .static : .relative)
		if pos == "sticky" { Diagnostics.warn("position:sticky treated as relative") }
		var inset: [String?] = [b["top"], b["right"], b["bottom"], b["left"]]
		if let i = CSS.box4(b["inset"]) { for k in 0..<4 where inset[k] == nil { inset[k] = i[k] } }
		for (k, e) in [YGEdge.top, .right, .bottom, .left].enumerated() {
			guard let s = inset[k] else { continue }
			switch CSS.length(s, cx) { case .px(let v): YGNodeStyleSetPosition(n, e, Float(v)); case .percent(let p): YGNodeStyleSetPositionPercent(n, e, Float(p)); default: break }
		}
		// sizes
		func dim(_ k: String, _ set: (YGNodeRef, Float) -> Void, _ pct: (YGNodeRef, Float) -> Void, _ auto: ((YGNodeRef) -> Void)?) {
			switch L(k) { case .px(let v): set(n, Float(v)); case .percent(let p): pct(n, Float(p)); case .auto: auto?(n); default: if let s = b[k], ["max-content", "fit-content", "min-content"].contains(s) { Diagnostics.warn("\(k): \(s) approximated as auto") } }
		}
		dim("width", YGNodeStyleSetWidth, YGNodeStyleSetWidthPercent, YGNodeStyleSetWidthAuto)
		dim("height", YGNodeStyleSetHeight, YGNodeStyleSetHeightPercent, YGNodeStyleSetHeightAuto)
		dim("minWidth", YGNodeStyleSetMinWidth, YGNodeStyleSetMinWidthPercent, nil)
		dim("minHeight", YGNodeStyleSetMinHeight, YGNodeStyleSetMinHeightPercent, nil)
		dim("maxWidth", YGNodeStyleSetMaxWidth, YGNodeStyleSetMaxWidthPercent, nil)
		dim("maxHeight", YGNodeStyleSetMaxHeight, YGNodeStyleSetMaxHeightPercent, nil)
		if let a = b["aspectRatio"] { let p = a.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }; if let w = p.first { YGNodeStyleSetAspectRatio(n, Float(p.count > 1 ? w / p[1] : w)) } }
		YGNodeStyleSetBoxSizing(n, (b["boxSizing"] ?? "border-box") == "content-box" ? .contentBox : .borderBox) // Remotion injects * { box-sizing: border-box }
		// margin / padding / border widths
		func edges(_ short: String, _ long: [String]) -> [String?] { var e: [String?] = long.map { b[$0] }; if let s = CSS.box4(b[short]) { for k in 0..<4 where e[k] == nil { e[k] = s[k] } }; return e }
		let m = edges("margin", ["marginTop", "marginRight", "marginBottom", "marginLeft"])
		var mx = b["marginInline"].flatMap { CSS.splitSpaces($0) }, my = b["marginBlock"].flatMap { CSS.splitSpaces($0) }
		if mx?.count == 1 { mx!.append(mx![0]) }; if my?.count == 1 { my!.append(my![0]) }
		let mm: [String?] = [m[0] ?? my?[0], m[1] ?? mx?[1], m[2] ?? my?[1], m[3] ?? mx?[0]]
		let p = edges("padding", ["paddingTop", "paddingRight", "paddingBottom", "paddingLeft"])
		var px = b["paddingInline"].flatMap { CSS.splitSpaces($0) }, py = b["paddingBlock"].flatMap { CSS.splitSpaces($0) }
		if px?.count == 1 { px!.append(px![0]) }; if py?.count == 1 { py!.append(py![0]) }
		let pp: [String?] = [p[0] ?? py?[0], p[1] ?? px?[1], p[2] ?? py?[1], p[3] ?? px?[0]]
		for (k, e) in [YGEdge.top, .right, .bottom, .left].enumerated() {
			if let s = mm[k] { switch CSS.length(s, cx) { case .px(let v): YGNodeStyleSetMargin(n, e, Float(v)); case .percent(let q): YGNodeStyleSetMarginPercent(n, e, Float(q)); case .auto: YGNodeStyleSetMarginAuto(n, e); default: break } }
			if let s = pp[k] { switch CSS.length(s, cx) { case .px(let v): YGNodeStyleSetPadding(n, e, Float(v)); case .percent(let q): YGNodeStyleSetPaddingPercent(n, e, Float(q)); default: break } }
			if let w = borderWidth(b, k, cx) { YGNodeStyleSetBorder(n, e, Float(w)) }
		}
		// gaps
		let gap = (b["gap"] ?? b["gridGap"]).map(CSS.splitSpaces)
		if let g = b["rowGap"] ?? b["gridRowGap"] ?? gap?.first, let v = CSS.resolve(CSS.length(g, cx), 0) { YGNodeStyleSetGap(n, .row, Float(v)) }
		if let g = b["columnGap"] ?? gap?.last, let v = CSS.resolve(CSS.length(g, cx), 0) { YGNodeStyleSetGap(n, .column, Float(v)) }
		if let o = b["overflow"] ?? b["overflowX"] ?? b["overflowY"], o != "visible" { YGNodeStyleSetOverflow(n, .hidden) }
		if (b.display == "grid" || b.display == "inline-grid") && gridColumns(b) != nil {
			// rows (see buildGrid) always span the container; align-content distributes them vertically
			YGNodeStyleSetAlignItems(n, .stretch)
			YGNodeStyleSetJustifyContent(n, ["center": .center, "end": .flexEnd, "flex-end": .flexEnd, "space-between": .spaceBetween, "space-around": .spaceAround, "space-evenly": .spaceEvenly][b["alignContent"] ?? ""] ?? .flexStart)
		}
	}

	// MARK: grid
	enum GridTrack: Equatable { case px(Double), percent(Double), fr(Double), auto }
	/// column tracks of a grid container (no template: one auto column); nil when the template isn't supported
	private func gridColumns(_ b: Box) -> [GridTrack]? { b["gridTemplateColumns"] == nil ? [.auto] : gridTracks(b["gridTemplateColumns"], b) }
	/// `grid-template-columns` / `-rows`: px, %, other lengths, fr, auto, minmax(a, b) (as b), repeat(N, …) and line names.
	/// nil for what needs the container size or content (auto-fill / auto-fit, subgrid, masonry).
	private func gridTracks(_ raw: String?, _ b: Box) -> [GridTrack]? {
		guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw != "none" else { return nil }
		let cx = CSS.Ctx(fontSize: b.cs.fontSize, vw: W, vh: H)
		func one(_ t: String) -> GridTrack? {
			let l = t.lowercased()
			if l.hasSuffix("fr"), let v = Double(l.dropLast(2)) { return .fr(v) }
			if ["auto", "min-content", "max-content"].contains(l) || l.hasPrefix("fit-content(") { return .auto }
			if l.hasPrefix("minmax("), l.hasSuffix(")") {
				let a = splitTopLevelCommas(l.dropFirst(7).dropLast())
				return a.count == 2 ? one(a[1]) ?? one(a[0]) : nil
			}
			switch CSS.length(l, cx) { case .px(let v): return .px(v); case .percent(let p): return .percent(p); case .auto: return .auto; default: return nil }
		}
		var out: [GridTrack] = []
		var inName = false
		for tok in CSS.splitSpaces(raw) {
			if tok.hasPrefix("[") || inName { inName = !tok.hasSuffix("]"); continue } // [line names]
			if tok.lowercased().hasPrefix("repeat("), tok.hasSuffix(")") {
				let a = splitTopLevelCommas(tok.dropFirst(7).dropLast())
				guard a.count == 2, let k = Int(a[0]), k > 0, let inner = gridTracks(a[1], b) else { return nil }
				for _ in 0..<min(k, 1000) { out += inner }
				continue
			}
			guard let t = one(tok) else { return nil }
			out.append(t)
		}
		return out.isEmpty ? nil : out
	}

	/// CSS grid for the common cases: fixed track lists (px, %, fr; auto columns count as 1fr), gaps, auto-placement
	/// in row order, justify/align-items/-self, justify-content (columns) and align-content (rows). It is built from
	/// Yoga flex boxes: the container is a column of anonymous rows (row-gap), each row a flex row of anonymous
	/// cells (column-gap) that carry the column tracks (fr → flex-grow with a zero basis, so every row splits the
	/// width the same way; missing cells of the last row are empty placeholders), and each cell holds one item.
	/// Auto rows are as tall as their tallest item and share leftover height (align-content: normal stretches
	/// them). Not modelled: explicit placement and spans (gridColumn / gridRow / gridArea), auto-fill/auto-fit,
	/// content-based track sizing (an fr column never grows to fit its min-content), grid-auto-flow: column/dense.
	private func buildGrid(_ b: Box, _ n: YGNodeRef, _ kids: [Box], _ colTracks: [GridTrack]) {
		let cols = colTracks.map { $0 == .auto ? GridTrack.fr(1) : $0 }
		func anon(_ tag: String, _ style: [String: String], _ display: String, _ children: [Box]) -> Box {
			let a = Box(tag: tag, style: style, attrs: [:], text: nil, markup: nil); a.cs = b.cs; a.display = display; a.parent = b
			a.children = children; for c in children { c.parent = a }
			return a
		}
		// items: in-flow children in order; each run of inline content becomes one anonymous item
		var items: [Box] = [], outOfFlow: [Box] = [], pending: [Box] = []
		func flush() {
			if pending.contains(where: { !$0.isText || !($0.text ?? "").allSatisfy(\.isWhitespace) }) { items.append(anon("#anon", [:], "block", pending)) }
			pending.removeAll()
		}
		for k in kids {
			if isInlineContent(k) { pending.append(k); continue }
			flush()
			if k.display == "none" || ["absolute", "fixed"].contains(k["position"] ?? "") { outOfFlow.append(k) } else { items.append(k) }
		}
		flush()
		if items.contains(where: { k in ["gridColumn", "gridRow", "gridArea", "gridColumnStart", "gridColumnEnd", "gridRowStart", "gridRowEnd"].contains { k[$0] != nil && k[$0] != "auto" } }) {
			Diagnostics.warn("grid item placement (gridColumn/gridRow/gridArea) ignored; items auto-placed in order")
		}
		if let f = b["gridAutoFlow"], f.contains("column") { Diagnostics.warn("grid-auto-flow: \(f) placed in row order") }
		if b["gridTemplateAreas"] != nil { Diagnostics.warn("grid-template-areas ignored") }
		let rowTracks = gridTracks(b["gridTemplateRows"], b) ?? []
		let autoRows = gridTracks(b["gridAutoRows"], b) ?? [.auto]
		let nRows = max(rowTracks.count, (items.count + cols.count - 1) / cols.count)
		func rowTrack(_ r: Int) -> GridTrack { r < rowTracks.count ? rowTracks[r] : autoRows[(r - rowTracks.count) % autoRows.count] }
		let gap = (b["gap"] ?? b["gridGap"]).map(CSS.splitSpaces)
		let colGap = b["columnGap"] ?? b["gridColumnGap"] ?? gap?.last
		let anyFrRow = (0..<nRows).contains { if case .fr = rowTrack($0) { return true }; return false }
		let stretchRows = ["normal", "stretch"].contains(b["alignContent"] ?? "normal") && !anyFrRow
		// alignment of an item inside its cell: block axis → cell justify-content, inline axis → cell align-items
		func split2(_ v: String?) -> (String?, String?) { guard let v else { return (nil, nil) }; let p = CSS.splitSpaces(v); return (p.first, p.count > 1 ? p[1] : p.first) }
		let (placeA, placeJ) = split2(b["placeItems"])
		let yMap = ["center": "center", "end": "flex-end", "flex-end": "flex-end", "self-end": "flex-end", "start": "flex-start", "flex-start": "flex-start", "self-start": "flex-start", "baseline": "flex-start"]
		let xMap = ["center": "center", "end": "flex-end", "flex-end": "flex-end", "self-end": "flex-end", "right": "flex-end", "start": "flex-start", "flex-start": "flex-start", "self-start": "flex-start", "left": "flex-start"]
		var rows: [Box] = []
		for r in 0..<nRows {
			var cells: [Box] = []
			for c in 0..<cols.count {
				var cs: [String: String] = ["minWidth": "0px"]
				switch cols[c] {
				case .px(let v): cs["width"] = "\(v)px"; cs["flexShrink"] = "0"
				case .percent(let p): cs["width"] = "\(p)%"; cs["flexShrink"] = "0"
				case .fr(let f): cs["flexGrow"] = "\(f)"; cs["flexBasis"] = "0px"; cs["flexShrink"] = "1"
				case .auto: break
				}
				var content: [Box] = []
				if r * cols.count + c < items.count {
					let it = items[r * cols.count + c]
					let (selfA, selfJ) = split2(it["placeSelf"])
					let ya = [it["alignSelf"], selfA].compactMap { $0 }.first { $0 != "auto" } ?? b["alignItems"] ?? placeA ?? "stretch"
					let xa = [it["justifySelf"], selfJ].compactMap { $0 }.first { $0 != "auto" } ?? b["justifyItems"] ?? placeJ ?? "stretch"
					if let v = yMap[ya] { cs["justifyContent"] = v }
					if let v = xMap[xa] { cs["alignItems"] = v }
					it.gridStretch = yMap[ya] == nil && [nil, "auto"].contains(it["height"])
					content = [it]
				}
				cells.append(anon("#grid-cell", cs, "grid-cell", content))
			}
			var rs: [String: String] = [:]
			if let g = colGap { rs["columnGap"] = g }
			if let j = b["justifyContent"] { rs["justifyContent"] = j }
			switch rowTrack(r) {
			case .px(let v): rs["height"] = "\(v)px"
			case .percent(let p): rs["height"] = "\(p)%"
			case .fr(let f): rs["flexGrow"] = "\(f)"; rs["flexBasis"] = "0px"
			case .auto: if stretchRows { rs["flexGrow"] = "1" }
			}
			rows.append(anon("#grid-row", rs, "flex", cells))
		}
		b.children = rows + outOfFlow
		for (i, k) in b.children.enumerated() { YGNodeInsertChild(n, yoga(k, parentDisplay: b.display), Int(i)) }
	}

	/// border width for side k (0 top, 1 right, 2 bottom, 3 left); nil when no visible border
	func borderWidth(_ b: Box, _ k: Int, _ cx: CSS.Ctx) -> Double? {
		let side = ["Top", "Right", "Bottom", "Left"][k]
		if let w = b["border\(side)Width"] { return CSS.px(w.lowercased(), cx) }
		if let s = b["border\(side)"] ?? b["border"] { return parseBorder(s, cx).0 }
		if let w = CSS.box4(b["borderWidth"]) { let st = b["borderStyle"] ?? "none"; return st == "none" ? nil : CSS.px(w[k].lowercased(), cx) ?? (["thin": 1, "medium": 3, "thick": 5][w[k]]) }
		return nil
	}
	func parseBorder(_ s: String, _ cx: CSS.Ctx) -> (Double?, RGBA?) {
		var w: Double? = nil, c: RGBA? = nil, styled = false
		for t in CSS.splitSpaces(s) {
			if ["solid", "dashed", "dotted", "double", "groove", "ridge", "inset", "outset"].contains(t) { styled = true; if t != "solid" { Diagnostics.warn("border-style \(t) drawn as solid") } }
			else if t == "none" || t == "hidden" { return (nil, nil) }
			else if let v = CSS.px(t.lowercased(), cx) { w = v } else if let v = ["thin": 1.0, "medium": 3, "thick": 5][t] { w = v } else if let col = CSS.color(t) { c = col }
		}
		return styled ? (w ?? 3, c) : (nil, nil)
	}

	private func intrinsicSize(_ b: Box) -> CGSize? {
		func attr(_ k: String) -> Double? { (b.attrs[k] as? String).flatMap { Double($0.replacingOccurrences(of: "px", with: "")) } }
		if b.markup != nil {
			if let w = attr("width"), let h = attr("height") { return CGSize(width: w, height: h) }
			if let vb = (b.attrs["viewBox"] as? String)?.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap({ Double($0) }), vb.count == 4 { return CGSize(width: vb[2], height: vb[3]) }
			return CGSize(width: 300, height: 150)
		}
		if let v = b.attrs["video"] as? String {
			if let s = videoSizes[v] { return s }
			let s = videoNaturalSize(v); videoSizes[v] = s; return s
		}
		if let p = b.attrs["src"] as? String {
			if let s = imageSizes[p] { return s }
			var s = CGSize(width: 0, height: 0)
			if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
			   let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double { s = CGSize(width: w, height: h) }
			imageSizes[p] = s; return s
		}
		return nil
	}

	// MARK: paint
	struct PaintCtx { var o = 1.0; var clip: [[Double]] = []; var fl: [String] = []; var bm: String? = nil; var visible = true }

	private func frame(_ b: Box) -> CGRect {
		guard let n = b.node else { return .zero }
		return CGRect(x: Double(YGNodeLayoutGetLeft(n)), y: Double(YGNodeLayoutGetTop(n)), width: Double(YGNodeLayoutGetWidth(n)), height: Double(YGNodeLayoutGetHeight(n)))
	}

	private func paint(_ b: Box, parent G0: CGAffineTransform, ctx c0: PaintCtx, ops: inout [[String: Any]]) {
		guard !b.isText, b.display != "none", let n = b.node, YGNodeStyleGetDisplay(n) != .none else { return }
		let f = frame(b)
		let cx = CSS.Ctx(fontSize: b.cs.fontSize, vw: W, vh: H)
		var c = c0
		c.visible = b.cs.visible
		// local → composition transform
		var G = CGAffineTransform(translationX: f.minX, y: f.minY).concatenating(G0)
		var tfStr = b["transform"]
		var extra: [String] = []
		if let t = b["translate"], t != "none" { let p = CSS.splitSpaces(t); extra.append("translate(\(p[0]), \(p.count > 1 ? p[1] : "0px"))") }
		if let r = b["rotate"], r != "none" { extra.append("rotate(\(r))") }
		if let s = b["scale"], s != "none" { let p = CSS.splitSpaces(s); extra.append("scale(\(p[0]), \(p.count > 1 ? p[1] : p[0]))") }
		if !extra.isEmpty { tfStr = extra.joined(separator: " ") + " " + (tfStr == "none" ? "" : tfStr ?? "") }
		if let T = CSS.transform(tfStr, w: f.width, h: f.height, cx) {
			let (ox, oy) = CSS.origin(b["transformOrigin"], w: f.width, h: f.height, cx)
			G = CGAffineTransform(translationX: -ox, y: -oy).concatenating(T).concatenating(CGAffineTransform(translationX: ox, y: oy)).concatenating(G)
		}
		if let o = b["opacity"].flatMap({ Double($0.hasSuffix("%") ? String($0.dropLast()) : $0).map { $0 > 1 && b["opacity"]!.hasSuffix("%") ? $0 / 100 : $0 } }) { c.o *= max(0, min(1, o)) }
		if c.o < 0.002 { return }
		let rot = abs(G.b) > 1e-4 || abs(G.c) > 1e-4
		let k = rot ? 1 : abs(G.d) // scale applied to font sizes / radii in axis-aligned mode
		if !rot && abs(abs(G.a) - abs(G.d)) > 0.01 * abs(G.d) { Diagnostics.warn("non-uniform scale on text/radius approximated") }

		// effects needing WebKit for this element only
		let (okF, badF) = CSS.filters(b["filter"], cx)
		var reason: String? = nil
		if b.markup != nil { reason = b.tag == "svg" ? "SVG" : b.tag }
		else if !badF.isEmpty { reason = "filter \(badF.joined(separator: " "))" }
		else if let cp = b["clipPath"] ?? b["WebkitClipPath"], cp != "none" { reason = "clip-path" }
		else if let mk = b["maskImage"] ?? b["WebkitMaskImage"] ?? b["mask"] ?? b["WebkitMask"], mk != "none" { reason = "mask" }
		else if let s = b.attrs["src"] as? String, s.lowercased().hasSuffix(".svg") { reason = "SVG image" }
		if let reason {
			if containsVideo(b) { Diagnostics.warn("\(reason) on an element containing video — ignored"); }
			else { rasterize(b, reason: reason, G: G, f: f, c: c, ops: &ops); return }
		}
		if !okF.isEmpty { c.fl += okF.map { $0.hasPrefix("blur(") ? "blur(\(CSS.fmt((Double($0.dropFirst(5).dropLast(3)) ?? 0) * k))px)" : $0 } }
		if let bm = b["mixBlendMode"], bm != "normal" { c.bm = bm; Diagnostics.warn("mix-blend-mode \(bm)") }

		let local = CGRect(x: 0, y: 0, width: f.width, height: f.height)
		func place(_ op: inout [String: Any], _ r: CGRect) {
			if rot {
				let q = r.applying(G); op["b"] = [q.minX, q.minY, q.width, q.height]
				// Painter rotates around the box center: carry the transformed center + local size
				let center = CGPoint(x: r.midX, y: r.midY).applying(G)
				op["b"] = [center.x - q.width / 2, center.y - q.height / 2, q.width, q.height]
				op["m"] = [G.a, G.b, G.c, G.d]; op["lb"] = [r.width, r.height]
			} else {
				let q = r.applying(G); op["b"] = [q.minX, q.minY, q.width, q.height]
			}
			op["o"] = c.o; op["c"] = c.clip
			if !c.fl.isEmpty { op["fl"] = c.fl }
			if let bm = c.bm { op["bm"] = bm }
		}

		if c.visible {
			// background, border, shadows
			var r: [String: Any] = ["t": "r"]
			let current = CSS.computed(b.cs.color)
			let bgShort = b["background"]
			var bgColor: RGBA? = b["backgroundColor"].flatMap { CSS.color($0, current: current) }
			var bgImage = b["backgroundImage"]
			if let s = bgShort {
				if s.contains("gradient(") || s.contains("url(") { bgImage = bgImage ?? s
					if let last = CSS.splitSpaces(splitTopLevelCommas(Substring(s)).last ?? "").last, let col = CSS.color(last) { bgColor = bgColor ?? col } }
				else if let col = CSS.color(s, current: current) ?? CSS.splitSpaces(s).compactMap({ CSS.color($0) }).last { bgColor = bgColor ?? col }
			}
			if let col = bgColor, col.a > 0 { r["bg"] = CSS.computed(col) }
			if let gi = bgImage, gi != "none" {
				if let g = CSS.normalizeGradients(gi, cx, current: current) { r["gi"] = g }
				if let m = gi.range(of: "url\\(\\s*[\"']?([^\"')]+)[\"']?\\s*\\)", options: .regularExpression) {
					let u = String(gi[m]).replacingOccurrences(of: "url(", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"') "))
					if let p = JSRuntimeBridge.resolve?(u) {
						var io: [String: Any] = ["t": "i", "src": p, "fit": ["cover": "cover", "contain": "contain"][b["backgroundSize"] ?? ""] ?? "fill", "r": radius(b, f, k)]
						place(&io, local); ops.append(io)
						if b["backgroundSize"] == nil { Diagnostics.warn("background-image url() without background-size drawn stretched") }
					}
				}
			}
			if let sh = CSS.shadows(b["boxShadow"], cx, current: current) { r["sh"] = sh.map { var s = $0; for key in ["x", "y", "b", "s"] { s[key] = (s[key] as! Double) * k }; return s } }
			let (bw, bc) = borderSpec(b, cx, current: current)
			if let bw, let bc, bw > 0 { r["br"] = ["w": bw * k, "c": CSS.computed(bc)] }
			if let bf = b["backdropFilter"] ?? b["WebkitBackdropFilter"], bf != "none" { let (ok, bad) = CSS.filters(bf, cx); if !ok.isEmpty { r["bf"] = ok }; if !bad.isEmpty { Diagnostics.warn("backdrop-filter \(bad.joined()) ignored") } }
			if r.count > 1 { r["r"] = radius(b, f, k); place(&r, local); ops.insert(r, at: ops.count) }
			// single-side borders (e.g. an accent bar via border-left): painted as strips, corners not rounded
			if r["br"] == nil {
				for (i, side) in ["Top", "Right", "Bottom", "Left"].enumerated() {
					guard let w = borderWidth(b, i, cx), w > 0 else { continue }
					var col: RGBA? = b["border\(side)Color"].flatMap { CSS.color($0, current: current) }
					if let sh = b["border\(side)"] { col = parseBorder(sh, cx).1 ?? col }
					let c = col ?? b.cs.color
					guard c.a > 0 else { continue }
					let strip: CGRect = [CGRect(x: 0, y: 0, width: f.width, height: w), CGRect(x: f.width - w, y: 0, width: w, height: f.height), CGRect(x: 0, y: f.height - w, width: f.width, height: w), CGRect(x: 0, y: 0, width: w, height: f.height)][i]
					var so: [String: Any] = ["t": "r", "bg": CSS.computed(c), "r": 0.0]; place(&so, strip); ops.append(so)
				}
			}
			if ["borderTopLeftRadius", "borderTopRightRadius", "borderBottomLeftRadius", "borderBottomRightRadius"].contains(where: { b[$0] != nil }) || (b["borderRadius"].map { CSS.splitSpaces($0).count > 1 && Set(CSS.splitSpaces($0)).count > 1 } ?? false) { Diagnostics.warn("per-corner border-radius drawn with one radius") }

			// replaced content
			if b.tag == "img" || b.tag == "video" {
				let (bl, bt, br_, bb) = (border(b, 3), border(b, 0), border(b, 1), border(b, 2))
				let (pl, pt, pr, pb) = (padding(b, .left), padding(b, .top), padding(b, .right), padding(b, .bottom))
				let content = CGRect(x: bl + pl, y: bt + pt, width: f.width - bl - br_ - pl - pr, height: f.height - bt - bb - pt - pb)
				var io: [String: Any] = ["t": "i", "fit": b["objectFit"] ?? "fill", "r": radius(b, f, k)]
				if let v = b.attrs["video"] as? String { io["v"] = ["src": v, "time": (b.attrs["time"] as? Double) ?? 0] } else if let s = b.attrs["src"] as? String { io["src"] = s }
				if io["v"] != nil || io["src"] != nil { place(&io, content); ops.append(io) }
			}
			if let p = b.paragraph { paintParagraph(p, b, f: f, G: G, k: k, rot: rot, c: c, ops: &ops) }
		}

		// children: stacking order (negative z, in-flow, positioned/auto, positive z)
		var cc = c
		if let n = b.node, YGNodeStyleGetOverflow(n) == .hidden {
			// CSS clips overflow at the padding box (inside the border), with the inner radius
			let bl = border(b, 3), bt = border(b, 0), br = border(b, 1), bb = border(b, 2)
			let pad = CGRect(x: bl, y: bt, width: max(0, f.width - bl - br), height: max(0, f.height - bt - bb))
			let rr = max(0, radius(b, f, 1) - max(bl, bt))
			if rot { cc.clip.append([pad.minX, pad.minY, pad.width, pad.height, rr, G.a, G.b, G.c, G.d, G.tx, G.ty].map { Double($0) }) }
			else { let q = pad.applying(G); cc.clip.append([q.minX, q.minY, q.width, q.height, rr * k].map { Double($0) }) }
		}
		let kids = b.children.filter { !$0.isText }
		let ordered = kids.enumerated().sorted { (a, z) in
			let ka = stackKey(a.element), kz = stackKey(z.element)
			return ka != kz ? ka < kz : a.offset < z.offset
		}.map(\.element)
		for ch in ordered { paint(ch, parent: G, ctx: cc, ops: &ops) }
	}
	private func stackKey(_ b: Box) -> Double {
		let pos = b["position"] ?? "static"
		let z = b["zIndex"].flatMap(Double.init)
		if pos == "static" { return z.map { _ in 0 } ?? 0 } // z-index has no effect on static boxes (except flex items; rare)
		if let z, z != 0 { return z < 0 ? -1e6 + z : 1e6 + z }
		return 1
	}
	private func containsVideo(_ b: Box) -> Bool { b.attrs["video"] != nil || b.children.contains(where: containsVideo) }
	private func border(_ b: Box, _ k: Int) -> Double { guard let n = b.node else { return 0 }; return Double(YGNodeLayoutGetBorder(n, [YGEdge.top, .right, .bottom, .left][k])) }
	private func padding(_ b: Box, _ e: YGEdge) -> Double { guard let n = b.node else { return 0 }; return Double(YGNodeLayoutGetPadding(n, e)) }
	private func borderSpec(_ b: Box, _ cx: CSS.Ctx, current: String) -> (Double?, RGBA?) {
		var w: Double? = nil, c: RGBA? = nil
		if let s = b["border"] { (w, c) = parseBorder(s, cx) }
		if let s = b["borderTop"] { let r = parseBorder(s, cx); w = r.0 ?? w; c = r.1 ?? c }
		if let s = b["borderWidth"] { w = CSS.px(CSS.splitSpaces(s)[0].lowercased(), cx) ?? w }
		if let s = b["borderTopWidth"] { w = CSS.px(s.lowercased(), cx) ?? w }
		if let s = b["borderColor"] ?? b["borderTopColor"] { c = CSS.color(CSS.splitSpaces(s)[0], current: current) ?? c }
		if let st = b["borderStyle"] ?? b["borderTopStyle"], st == "none" || st == "hidden" { return (nil, nil) }
		if w != nil && (b["borderStyle"] != nil || b["borderTopStyle"] != nil || b["border"] != nil || b["borderTop"] != nil) && c == nil { c = b.cs.color }
		if b["border"] == nil && b["borderTop"] == nil && b["borderStyle"] == nil && b["borderTopStyle"] == nil { return (nil, nil) }
		return (w, c)
	}
	private func radius(_ b: Box, _ f: CGRect, _ k: Double) -> Double {
		guard let s = b["borderRadius"] ?? b["borderTopLeftRadius"] else { return 0 }
		let first = CSS.splitSpaces(s.split(separator: "/").first.map(String.init) ?? s).first ?? "0"
		let cx = CSS.Ctx(fontSize: b.cs.fontSize, vw: W, vh: H)
		let v: Double
		switch CSS.length(first, cx) { case .px(let p): v = p; case .percent(let p): v = p / 100 * min(f.width, f.height); default: v = 0 }
		return min(v, min(f.width, f.height) / 2) * k
	}

	// MARK: text painting
	private func paintParagraph(_ p: Paragraph, _ b: Box, f: CGRect, G: CGAffineTransform, k: Double, rot: Bool, c: PaintCtx, ops: inout [[String: Any]]) {
		let bl = border(b, 3), bt = border(b, 0), br = border(b, 1), bb = border(b, 2)
		let pl = padding(b, .left), pt = padding(b, .top), pr = padding(b, .right), pb = padding(b, .bottom)
		let content = CGRect(x: bl + pl, y: bt + pt, width: max(0, f.width - bl - br - pl - pr), height: max(0, f.height - bt - bb - pt - pb))
		let lines = p.layout(width: content.width)
		var y = content.minY
		let align = b.cs.textAlign
		for line in lines {
			let free = content.width - line.width
			var x0 = content.minX
			switch align { case "center", "-webkit-center": x0 += free / 2; case "right", "-webkit-right": x0 += free; case "end": x0 += b.cs.direction == "rtl" ? 0 : free; case "start": x0 += b.cs.direction == "rtl" ? free : 0; default: break }
			var runs = line.runs
			if align == "justify" {
				// full lines are stretched word by word; the last line (text-align-last: auto) is start-aligned
				if let j = p.justified(line, width: content.width) { runs = j } else if b.cs.direction == "rtl" { x0 += free }
			}
			for run in runs where !run.text.isEmpty && run.style.visible {
				let s = run.style
				let local = CGRect(x: x0 + run.x, y: y + line.baseline - run.ascent, width: run.width, height: run.ascent + run.descent)
				var op: [String: Any] = ["t": "x", "s": run.text, "ff": s.fontFamily, "fw": s.fontWeight, "fs": s.fontSize * k, "fi": s.italic ? 1 : 0, "col": CSS.computed(s.color), "ls": s.letterSpacing * k]
				if let ts = CSS.shadows(s.textShadow, CSS.Ctx(fontSize: s.fontSize, vw: W, vh: H), current: CSS.computed(s.color)) { op["ts"] = ts.map { var d = $0; for key in ["x", "y", "b"] { d[key] = (d[key] as! Double) * k }; return d } }
				if rot { op["fs"] = s.fontSize; op["ls"] = s.letterSpacing }
				if rot { placeRot(&op, local, G) } else { let q = local.applying(G); op["b"] = [q.minX, q.minY, q.width, q.height] }
				op["o"] = c.o; op["c"] = c.clip
				if !c.fl.isEmpty { op["fl"] = c.fl }
				if let bm = c.bm { op["bm"] = bm }
				ops.append(op)
			}
			y += line.height
		}
	}
	private func placeRot(_ op: inout [String: Any], _ r: CGRect, _ G: CGAffineTransform) {
		let q = r.applying(G), center = CGPoint(x: r.midX, y: r.midY).applying(G)
		op["b"] = [center.x - q.width / 2, center.y - q.height / 2, q.width, q.height]
		op["m"] = [G.a, G.b, G.c, G.d]; op["lb"] = [r.width, r.height]
	}

	// MARK: WebKit fallback for one element
	/// WebKit renders the element once in its own local space (supersampled when scaled up); the Painter then applies
	/// the element's transform, opacity and clips on the GPU. Animating transform/opacity therefore never re-renders.
	private func rasterize(_ b: Box, reason: String, G: CGAffineTransform, f: CGRect, c: PaintCtx, ops: inout [[String: Any]]) {
		guard let fallback else { Diagnostics.warn("\(reason) skipped (WebKit fallback disabled)"); return }
		guard f.width > 0, f.height > 0 else { return }
		let pad = (b["filter"] ?? "").contains("drop-shadow") || (b["filter"] ?? "").contains("blur") ? 48.0 : 2.0 // room for effects that paint outside the box
		let scale = max(abs(G.a) + abs(G.c), abs(G.b) + abs(G.d))
		let ss = scale <= 1.01 ? 1.0 : min(4, ceil(scale * 2) / 2) // supersample in 0.5 steps so small animations reuse the bitmap
		let size = CGSize(width: ceil((f.width + 2 * pad) * ss), height: ceil((f.height + 2 * pad) * ss))
		let html = Markup.element(b, size: f.size, root: true)
		let m = CGAffineTransform(translationX: pad, y: pad).concatenating(CGAffineTransform(scaleX: ss, y: ss))
		guard let png = fallback.render(html: html, inherited: b.parent?.cs ?? b.cs, matrix: m, opacity: 1, size: size, fontFaces: faceRules.joined(separator: " ")) else { Diagnostics.warn("WebKit could not render \(reason)"); return }
		Diagnostics.warn("rendered by WebKit (once, then cached): \(reason)")
		let local = CGRect(x: -pad, y: -pad, width: size.width / ss, height: size.height / ss)
		let rot = abs(G.b) > 1e-4 || abs(G.c) > 1e-4
		var op: [String: Any] = ["t": "i", "src": png, "fit": "fill", "r": 0.0, "o": c.o, "c": c.clip]
		if rot { placeRot(&op, local, G) } else { let q = local.applying(G); op["b"] = [q.minX, q.minY, q.width, q.height] }
		if !c.fl.isEmpty { op["fl"] = c.fl }
		if let bm = c.bm { op["bm"] = bm }
		ops.append(op)
	}
}

/// Late-bound URL resolver for background-image url() (set by the runtime host).
enum JSRuntimeBridge { nonisolated(unsafe) static var resolve: ((String) -> String?)? }

extension Box {
	var className: String { (attrs["class"] as? String) ?? "" }
}

// MARK: - Yoga measure callbacks (C function pointers; context = Box)
private let measureParagraph: YGMeasureFunc = { node, width, wMode, _, _ in
	let b = Unmanaged<Box>.fromOpaque(YGNodeGetContext(node)!).takeUnretainedValue()
	guard let p = b.paragraph else { return YGSize(width: 0, height: 0) }
	let maxW = p.maxContentWidth
	let w: Double
	switch wMode { case .exactly: w = Double(width); case .atMost: w = min(Double(width), maxW); default: w = maxW }
	let lines = p.layout(width: w)
	let h = lines.reduce(0) { $0 + $1.height }
	let used = wMode == .exactly ? w : min(w, lines.map(\.width).max() ?? 0)
	return YGSize(width: Float(ceil(max(used, 0) * 64) / 64), height: Float(h))
}
private let measureReplaced: YGMeasureFunc = { node, width, wMode, height, hMode in
	let b = Unmanaged<Box>.fromOpaque(YGNodeGetContext(node)!).takeUnretainedValue()
	let s = b.intrinsic ?? CGSize(width: 300, height: 150)
	var w = Double(s.width), h = Double(s.height)
	if wMode == .exactly { w = Double(width) } else if wMode == .atMost { w = min(w, Double(width)) }
	if hMode == .exactly { h = Double(height) } else if hMode == .atMost { h = min(h, Double(height)) }
	return YGSize(width: Float(w), height: Float(h))
}
