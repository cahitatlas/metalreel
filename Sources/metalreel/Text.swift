// Paragraph layout with Core Text, following Chrome's inline layout rules closely enough that line
// breaks land on the same words:
//   • white-space processing (normal / nowrap / pre / pre-wrap / pre-line), collapsing across runs;
//   • break opportunities after spaces, after hyphens and around CJK ideographs (greedy, first fit);
//   • widths from one CTTypesetter over the whole paragraph, trailing spaces hang (not counted);
//   • line box = strut + runs, half-leading split like LayoutNG, font metrics rounded like Blink;
//   • letter-spacing after every character, text-transform, <br>.
// Fonts come from the same FontRegistry the Painter draws with, so measured and painted glyphs match.
import Foundation
import CoreText
import CoreGraphics

final class Paragraph {
	struct Piece { let text: String; let style: Computed }
	struct PlacedRun { let text: String; let style: Computed; let x: Double; let width: Double; let ascent: Double; let descent: Double }
	struct Line { let width: Double; let height: Double; let baseline: Double; let runs: [PlacedRun] }

	private(set) var pieces: [Piece] = []
	private var forcedBreaks = Set<Int>() // UTF-16 offsets where a <br> or preserved newline forces a break
	private var runStarts: [Int] = []     // UTF-16 start offset of each piece
	private let strut: Computed
	private let fonts: FontRegistry
	private var full = NSMutableAttributedString()
	private var utf16: [UInt16] = []
	private var typesetter: CTTypesetter?
	private var primaries: [CTFont] = []
	private var cache: [Int: [Line]] = [:]
	var isEmpty: Bool { utf16.isEmpty || utf16.allSatisfy { $0 == 32 } }

	init(owner: Box, fonts: FontRegistry, ctx: CSS.Ctx) {
		self.fonts = fonts; strut = owner.cs
		var lastSpace = true
		var pending = ""
		var pendingStyle: Computed? = nil
		func commit() {
			guard let st = pendingStyle, !pending.isEmpty else { pending = ""; return }
			pieces.append(Piece(text: pending, style: st)); runStarts.append(utf16.count)
			utf16.append(contentsOf: pending.utf16); pending = ""
		}
		var depth = 0
		func walk(_ b: Box) {
			depth += 1; defer { depth -= 1 }
			if depth > 60 { log("walk too deep at <\(b.tag)> children=\(b.children.map(\.tag)) self-child=\(b.children.contains { $0 === b })"); return }
			if b.display == "br" { commit(); forcedBreaks.insert(utf16.count); lastSpace = true; return }
			if let t = b.text { add(t, b.cs); return }
			if b.display == "none" { return }
			if b.markup != nil || b.tag == "img" || b.tag == "video" { Diagnostics.warn("inline \(b.tag) inside text is skipped"); return }
			let deco = ["backgroundColor", "background", "padding", "paddingLeft", "paddingRight", "border", "borderRadius", "boxShadow"].filter { b[$0] != nil }
			if !deco.isEmpty && b !== owner { Diagnostics.warn("decoration on inline <\(b.tag)> (\(deco.joined(separator: ", "))) not painted natively") }
			for c in b.children { walk(c) }
		}
		func add(_ raw: String, _ st: Computed) {
			var s = raw
			switch st.textTransform { case "uppercase": s = s.uppercased(); case "lowercase": s = s.lowercased(); case "capitalize": s = s.capitalized; default: break }
			let ws = st.whiteSpace
			let keepNewlines = ws == "pre" || ws == "pre-wrap" || ws == "pre-line" || ws == "break-spaces"
			let keepSpaces = ws == "pre" || ws == "pre-wrap" || ws == "break-spaces"
			if pendingStyle.map({ !Paragraph.same($0, st) }) ?? true { commit(); pendingStyle = st }
			for ch in s {
				if ch == "\n" || ch == "\r\n" {
					if keepNewlines { commit(); forcedBreaks.insert(utf16.count); lastSpace = !keepSpaces; continue }
				}
				if ch == " " || ch == "\t" || ch == "\n" || ch == "\r\n" || ch == "\r" || ch == "\u{0C}" {
					if keepSpaces { pending.append(ch == "\t" ? "        " : " "); continue }
					if !lastSpace { pending.append(" "); lastSpace = true }
					continue
				}
				pending.append(ch); lastSpace = false
			}
		}
		walk(owner)
		commit()
		// strip a trailing collapsible space at the end of the paragraph
		if let last = pieces.last, !["pre", "pre-wrap"].contains(last.style.whiteSpace), last.text.hasSuffix(" ") {
			pieces[pieces.count - 1] = Piece(text: String(last.text.dropLast()), style: last.style); utf16.removeLast()
		}
		if isEmpty { return }
		for p in pieces {
			let (a, f) = fonts.attributed(p.text, p.style.fontFamily, p.style.fontWeight, p.style.fontSize, p.style.italic, cgColor(p.style.color), p.style.letterSpacing)
			full.append(a); primaries.append(f)
		}
		typesetter = CTTypesetterCreateWithAttributedString(full)
	}
	static func same(_ a: Computed, _ b: Computed) -> Bool {
		a.fontFamily == b.fontFamily && a.fontSize == b.fontSize && a.fontWeight == b.fontWeight && a.italic == b.italic && a.color.r == b.color.r && a.color.g == b.color.g && a.color.b == b.color.b && a.color.a == b.color.a
			&& a.letterSpacing == b.letterSpacing && a.textShadow == b.textShadow && a.visible == b.visible && a.whiteSpace == b.whiteSpace
	}

	// MARK: measuring
	private func width(_ a: Int, _ b: Int) -> Double {
		guard let ts = typesetter, b > a else { return 0 }
		let line = CTTypesetterCreateLine(ts, CFRange(location: a, length: b - a))
		return CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
	}
	private func isCJK(_ u: UInt16) -> Bool { (0x2E80...0x9FFF).contains(u) || (0xAC00...0xD7AF).contains(u) || (0xF900...0xFAFF).contains(u) || (0xFF00...0xFFEF).contains(u) }
	private func style(at i: Int) -> Computed { pieces[pieceIndex(i)].style }
	private func pieceIndex(_ i: Int) -> Int { var lo = 0, hi = runStarts.count - 1; while lo < hi { let m = (lo + hi + 1) / 2; if runStarts[m] <= i { lo = m } else { hi = m - 1 } }; return lo }
	/// offsets where a new line may start
	private lazy var opportunities: [Int] = {
		var o: [Int] = []
		for i in 0..<utf16.count {
			let u = utf16[i], st = style(at: i)
			if st.whiteSpace == "nowrap" || st.whiteSpace == "pre" { continue }
			if u == 32 || u == 0x200B { if i + 1 < utf16.count, utf16[i + 1] != 32 { o.append(i + 1) } }
			else if (u == 0x2D || u == 0x2010 || u == 0x2013 || u == 0x2014), i + 1 < utf16.count, utf16[i + 1] != 32, i > 0, utf16[i - 1] != 32 { o.append(i + 1) }
			else if isCJK(u), i + 1 < utf16.count, !(0xFF01...0xFF0F).contains(utf16[i + 1]), utf16[i + 1] != 0x3001, utf16[i + 1] != 0x3002 { o.append(i + 1) }
		}
		return o
	}()
	lazy var maxContentWidth: Double = {
		var w = 0.0, start = 0
		for e in (forcedBreaks.sorted() + [utf16.count]) where e >= start { w = max(w, width(start, e)); start = e }
		return ceil(w * 64) / 64
	}()

	// MARK: line layout
	func layout(width avail: Double) -> [Line] {
		let key = Int((avail * 64).rounded())
		if let c = cache[key] { return c }
		var lines: [Line] = []
		var start = 0
		let n = utf16.count
		let hard = forcedBreaks.sorted()
		let eps = 1.0 / 64
		while start < n || (start == n && hard.contains(n) && lines.count < hard.count) {
			let hardEnd = hard.first { $0 > start } ?? n
			var end = hardEnd
			if width(start, hardEnd) > avail + eps {
				var best: Int? = nil
				for o in opportunities where o > start && o < hardEnd {
					if width(start, o) <= avail + eps { best = o } else { break }
				}
				if let best { end = best }
				else {
					end = opportunities.first { $0 > start && $0 < hardEnd } ?? hardEnd // a single word wider than the line overflows (like Chrome)
					if strut.overflowWrap == "break-word" || strut.overflowWrap == "anywhere", let ts = typesetter {
						let k = CTTypesetterSuggestClusterBreak(ts, start, avail); if k > 0 { end = start + k }
					}
				}
			}
			lines.append(makeLine(start, end))
			start = end
			while start < n, utf16[start] == 32, !["pre", "pre-wrap"].contains(style(at: start).whiteSpace) { start += 1 }
			if end == hardEnd && hardEnd == n { break }
		}
		if lines.isEmpty { lines.append(makeLine(0, 0)) }
		cache[key] = lines
		return lines
	}

	private func metrics(_ f: CTFont, _ st: Computed) -> (a: Double, d: Double, lh: Double) {
		let a = Double(CTFontGetAscent(f)).rounded(), d = Double(CTFontGetDescent(f)).rounded(), g = max(0, Double(CTFontGetLeading(f)).rounded())
		let lh: Double
		switch st.lineHeight { case .normal: lh = a + d + g; case .px(let v): lh = v; case .factor(let k): lh = k * st.fontSize }
		return (a, d, lh)
	}
	private lazy var strutFont: CTFont = primaries.first ?? fonts.font(strut.fontFamily, strut.fontWeight, strut.fontSize)

	private func makeLine(_ a: Int, _ b: Int) -> Line {
		var trimEnd = b
		while trimEnd > a, utf16[trimEnd - 1] == 32, !["pre", "pre-wrap"].contains(style(at: trimEnd - 1).whiteSpace) { trimEnd -= 1 }
		// strut
		let sm = metrics(strutFont, strut)
		func split(_ m: (a: Double, d: Double, lh: Double)) -> (Double, Double) {
			let hl = (m.lh - (m.a + m.d)) / 2
			let above = m.a + floor(hl * 64) / 64
			return (above, m.lh - above)
		}
		var (maxAbove, maxBelow) = split(sm)
		var runs: [PlacedRun] = []
		guard trimEnd > a, let ts = typesetter else { return Line(width: 0, height: maxAbove + maxBelow, baseline: maxAbove, runs: []) }
		let line = CTTypesetterCreateLine(ts, CFRange(location: a, length: trimEnd - a))
		let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
		var i = a
		let ns = full.string as NSString
		while i < trimEnd {
			let pi = pieceIndex(i)
			let segEnd = min(trimEnd, pi + 1 < runStarts.count ? runStarts[pi + 1] : trimEnd)
			let st = pieces[pi].style
			let m = metrics(primaries[pi], st)
			let (ab, be) = split(m)
			maxAbove = max(maxAbove, ab); maxBelow = max(maxBelow, be)
			let x0 = Double(CTLineGetOffsetForStringIndex(line, i, nil)), x1 = segEnd >= trimEnd ? lineWidth : Double(CTLineGetOffsetForStringIndex(line, segEnd, nil))
			let single = a == runStarts[pi] && segEnd == trimEnd && i == a
			runs.append(PlacedRun(text: ns.substring(with: NSRange(location: i, length: segEnd - i)), style: st, x: single ? 0 : min(x0, x1), width: single ? lineWidth : abs(x1 - x0), ascent: m.a, descent: m.d))
			i = segEnd
		}
		return Line(width: lineWidth, height: maxAbove + maxBelow, baseline: maxAbove, runs: runs)
	}
}
