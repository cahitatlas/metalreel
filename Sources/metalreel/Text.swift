// Paragraph layout with Core Text, following Chrome's inline layout rules closely enough that line
// breaks land on the same words:
//   • white-space processing (normal / nowrap / pre / pre-wrap / pre-line), collapsing across runs;
//   • break opportunities after spaces, after hyphens and around CJK ideographs (greedy, first fit);
//   • widths from one CTTypesetter over the whole paragraph, trailing spaces hang (not counted);
//   • line box = strut + runs, half-leading split like LayoutNG, font metrics rounded like Blink;
//   • per-character font fallback walks the font-family list like Blink before Core Text's cascade;
//   • line-height: normal also counts the metrics of fallback fonts the line uses (Blink's AccumulateUsedFonts);
//   • text-align: justify spreads free space over the spaces of every line but the last (see `justified`);
//   • letter-spacing after every character, text-transform, <br>.
// Fonts come from the same FontRegistry the Painter draws with, so measured and painted glyphs match.
import Foundation
import CoreText
import CoreGraphics

final class Paragraph {
	struct Piece { let text: String; let style: Computed }
	struct PlacedRun { let text: String; let style: Computed; let x: Double; let width: Double; let ascent: Double; let descent: Double }
	struct Line {
		let width: Double; let height: Double; let baseline: Double; let runs: [PlacedRun]
		var start = 0, end = 0       // UTF-16 range of the line, trailing collapsible spaces trimmed
		var last = true              // last line of the paragraph or ends at a forced break (never justified)
	}

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
		pieces = pieces.flatMap(fallbackSplit)
		runStarts = []
		var offset = 0
		for p in pieces { runStarts.append(offset); offset += p.text.utf16.count }
		for p in pieces {
			let (a, f) = fonts.attributed(p.text, p.style.fontFamily, p.style.fontWeight, p.style.fontSize, p.style.italic, cgColor(p.style.color), p.style.letterSpacing)
			full.append(a); primaries.append(f)
		}
		typesetter = CTTypesetterCreateWithAttributedString(full)
	}
	// MARK: font fallback
	/// Blink's FontFallbackList: a character the first font can't draw goes to the next family in `font-family` that
	/// has a glyph for it, and only then to the system fallback. The FontRegistry resolves page-loaded faces by
	/// unicode-range; Core Text's own cascade would skip installed families further down the list. Example: Arabic
	/// in `Inter, "Helvetica Neue", Arial, sans-serif` is drawn by Chrome with Arial (macOS Arial has Arabic), while
	/// Core Text's cascade from Inter picks Geeza Pro (wider, and its larger line gap makes the line box taller).
	/// Such runs become their own piece whose family list starts with the covering family, so measuring and
	/// painting use the same font.
	private func fallbackSplit(_ p: Piece) -> [Piece] {
		let st = p.style
		let names = st.fontFamily.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }.filter { !$0.isEmpty }
		guard names.count > 1, !p.text.isEmpty else { return [p] }
		let (a, _) = fonts.attributed(p.text, st.fontFamily, st.fontWeight, st.fontSize, st.italic, cgColor(st.color), st.letterSpacing)
		let key = NSAttributedString.Key(kCTFontAttributeName as String)
		func covers(_ f: CTFont, _ s: String) -> Bool {
			let u = Array(s.utf16); var g = [CGGlyph](repeating: 0, count: u.count)
			return CTFontGetGlyphsForCharacters(f, u, &g, u.count)
		}
		var missing = false
		a.enumerateAttribute(key, in: NSRange(location: 0, length: a.length)) { v, r, stop in
			if let v, !covers(v as! CTFont, (a.string as NSString).substring(with: r)) { missing = true; stop.pointee = true }
		}
		guard missing else { return [p] }
		func family(for ch: Unicode.Scalar) -> String? {
			for n in names {
				let k = n.lowercased()
				if fonts.faces[k] != nil { continue } // page-loaded faces: already chosen by unicode-range
				guard fonts.families[k] != nil || Paragraph.installed(k) else { continue }
				if covers(fonts.font(n, st.fontWeight, st.fontSize), String(ch)) { return n }
			}
			return nil
		}
		var out: [Piece] = []
		var cur = "", curFamily: String? = nil
		func flush() {
			guard !cur.isEmpty else { return }
			var s2 = st
			if let f = curFamily { s2.fontFamily = (f.contains(" ") ? "\"\(f)\"" : f) + ", " + st.fontFamily }
			out.append(Piece(text: cur, style: s2)); cur = ""
		}
		var o = 0
		for ch in p.text.unicodeScalars {
			let mark = [.nonspacingMark, .spacingMark, .enclosingMark].contains(ch.properties.generalCategory) || ch.value == 0x200D || (0xFE00...0xFE0F).contains(ch.value)
			var fam = curFamily
			if !mark || cur.isEmpty {
				let assigned = a.attribute(key, at: o, effectiveRange: nil).map { $0 as! CTFont }
				fam = assigned.map { covers($0, String(ch)) } ?? false ? nil : family(for: ch)
			}
			if fam != curFamily { flush(); curFamily = fam }
			cur.unicodeScalars.append(ch); o += ch.utf16.count
		}
		flush()
		return out
	}
	private nonisolated(unsafe) static var installedFamilies: [String: Bool] = [:]
	static func installed(_ family: String) -> Bool {
		if family.hasPrefix(".") { return true }
		if let v = installedFamilies[family] { return v }
		let d = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
		let v = ((CTFontDescriptorCreateMatchingFontDescriptors(d, nil) as? [CTFontDescriptor]) ?? []).isEmpty == false
		installedFamilies[family] = v; return v
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
			lines.append(makeLine(start, end, last: end == hardEnd))
			start = end
			while start < n, utf16[start] == 32, !["pre", "pre-wrap"].contains(style(at: start).whiteSpace) { start += 1 }
			if end == hardEnd && hardEnd == n { break }
		}
		if lines.isEmpty { lines.append(makeLine(0, 0)) }
		cache[key] = lines
		return lines
	}

	private func metrics(_ f: CTFont, _ st: Computed) -> (a: Double, d: Double, lh: Double) { Paragraph.metrics(f, st) }
	static func metrics(_ f: CTFont, _ st: Computed) -> (a: Double, d: Double, lh: Double) {
		let a = Double(CTFontGetAscent(f)).rounded(), d = Double(CTFontGetDescent(f)).rounded(), g = max(0, Double(CTFontGetLeading(f)).rounded())
		let lh: Double
		// a computed line-height becomes a LayoutUnit by truncation (24px × 1.4 = 33.6 → 33.59375)
		switch st.lineHeight { case .normal: lh = a + d + g; case .px(let v): lh = floor(v * 64) / 64; case .factor(let k): lh = floor(k * st.fontSize * 64) / 64 }
		return (a, d, lh)
	}
	/// half-leading like LayoutNG's CalculateLeadingSpace: the part above the baseline is floored to a whole pixel,
	/// the rest goes below (Inter 18px at line-height 1.3: 17 + 1 above, 4 + 1.390625 below; Inter 800 92px at 1.08:
	/// 89 − 6 above, Chrome places that text box exactly 6 px above the line top)
	static func split(_ m: (a: Double, d: Double, lh: Double)) -> (Double, Double) {
		let hl = (m.lh - (m.a + m.d)) / 2
		let above = m.a + floor(hl)
		return (above, m.lh - above)
	}
	/// A block's strut (root inline box) as (above, below) the baseline. Its primary font is the face that the
	/// font-family list gives U+0020, like Blink's PrimaryFont().
	static func strut(_ st: Computed, _ fonts: FontRegistry) -> (Double, Double) {
		let (_, f) = fonts.attributed(" ", st.fontFamily, st.fontWeight, st.fontSize, st.italic, cgColor(st.color), 0)
		return split(metrics(f, st))
	}
	private lazy var strutFont: CTFont = primaries.first ?? fonts.font(strut.fontFamily, strut.fontWeight, strut.fontSize)

	private func makeLine(_ a: Int, _ b: Int, last: Bool = true) -> Line {
		var trimEnd = b
		while trimEnd > a, utf16[trimEnd - 1] == 32, !["pre", "pre-wrap"].contains(style(at: trimEnd - 1).whiteSpace) { trimEnd -= 1 }
		// strut
		let sm = metrics(strutFont, strut)
		let split = Paragraph.split
		var (maxAbove, maxBelow) = split(sm)
		var runs: [PlacedRun] = []
		guard trimEnd > a, let ts = typesetter else { return Line(width: 0, height: maxAbove + maxBelow, baseline: maxAbove, runs: [], start: a, end: a, last: last) }
		let line = CTTypesetterCreateLine(ts, CFRange(location: a, length: trimEnd - a))
		let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
		// Fonts Core Text actually used on this line (fallbacks for glyphs the primary font lacks), by UTF-16 range
		let used: [(CFRange, CTFont)] = (CTLineGetGlyphRuns(line) as! [CTRun]).compactMap { r in
			let attrs = CTRunGetAttributes(r) as NSDictionary
			guard let f = attrs[kCTFontAttributeName as String] else { return nil }
			return (CTRunGetStringRange(r), f as! CTFont)
		}
		let rtl = Paragraph.hasRTL(line)
		var i = a
		let ns = full.string as NSString
		while i < trimEnd {
			let pi = pieceIndex(i)
			let segEnd = min(trimEnd, pi + 1 < runStarts.count ? runStarts[pi + 1] : trimEnd)
			let st = pieces[pi].style
			let m = metrics(primaries[pi], st)
			let (ab, be) = split(m)
			maxAbove = max(maxAbove, ab); maxBelow = max(maxBelow, be)
			// line-height: normal → Blink unites the box with every font the text was shaped with (primary and
			// fallbacks), each with its own ascent/descent and half of its own line gap. E.g. Arabic in
			// `Inter, 'Geeza Pro'` makes the line 38 px tall at 28 px instead of Inter's 34 px. A fixed line-height
			// ignores fallback fonts.
			if case .normal = st.lineHeight {
				for (r, f) in used where r.location < segEnd && r.location + r.length > i {
					let (fa, fb) = split(metrics(f, st))
					maxAbove = max(maxAbove, fa); maxBelow = max(maxBelow, fb)
				}
			}
			var x0 = Double(CTLineGetOffsetForStringIndex(line, i, nil)), x1 = segEnd >= trimEnd ? lineWidth : Double(CTLineGetOffsetForStringIndex(line, segEnd, nil))
			// caret offsets are logical; with right-to-left runs the segment's glyphs give its visual extent
			if rtl, let e = Paragraph.extent(line, i, segEnd) { (x0, x1) = e }
			let single = a == runStarts[pi] && segEnd == trimEnd && i == a
			runs.append(PlacedRun(text: ns.substring(with: NSRange(location: i, length: segEnd - i)), style: st, x: single ? 0 : min(x0, x1), width: single ? lineWidth : abs(x1 - x0), ascent: m.a, descent: m.d))
			i = segEnd
		}
		return Line(width: lineWidth, height: maxAbove + maxBelow, baseline: maxAbove, runs: runs, start: a, end: trimEnd, last: last)
	}

	static func hasRTL(_ line: CTLine) -> Bool {
		(CTLineGetGlyphRuns(line) as! [CTRun]).contains { CTRunGetStatus($0).contains(.rightToLeft) }
	}
	/// visual x extent (from the line origin) of the glyphs for UTF-16 range [i, j)
	static func extent(_ line: CTLine, _ i: Int, _ j: Int) -> (Double, Double)? {
		var lo = Double.infinity, hi = -Double.infinity
		for r in CTLineGetGlyphRuns(line) as! [CTRun] {
			let n = CTRunGetGlyphCount(r), rr = CTRunGetStringRange(r)
			guard n > 0, rr.location < j, rr.location + rr.length > i else { continue }
			var idx = [CFIndex](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n), adv = [CGSize](repeating: .zero, count: n)
			CTRunGetStringIndices(r, CFRange(location: 0, length: 0), &idx)
			CTRunGetPositions(r, CFRange(location: 0, length: 0), &pos)
			CTRunGetAdvances(r, CFRange(location: 0, length: 0), &adv)
			for g in 0..<n where idx[g] >= i && idx[g] < j { lo = min(lo, Double(pos[g].x)); hi = max(hi, Double(pos[g].x + adv[g].width)) }
		}
		return lo <= hi ? (lo, hi) : nil
	}

	/// text-align: justify, like Blink: on every line except the last one and lines ending at a forced break, the free
	/// space is divided equally among the expansion opportunities (spaces; Blink's `TreatAsSpace` also counts U+00A0).
	/// Lines without an opportunity, or that overflow, stay start-aligned (nil). The Painter draws each run as one
	/// string, so the line is returned as one run per word (and per style change inside a word), each at its
	/// measured position plus the extra space of the opportunities visually before it.
	func justified(_ line: Line, width avail: Double) -> [PlacedRun]? {
		guard !line.last, line.end > line.start, let ts = typesetter else { return nil }
		let free = avail - line.width
		let isSpace = { (u: UInt16) in u == 32 || u == 0xA0 }
		let spaces = (line.start..<line.end).filter { isSpace(utf16[$0]) }
		guard free > 1.0 / 64, !spaces.isEmpty else { return nil }
		let extra = free / Double(spaces.count)
		let ct = CTTypesetterCreateLine(ts, CFRange(location: line.start, length: line.end - line.start))
		let rtl = Paragraph.hasRTL(ct)
		func offset(_ k: Int) -> Double { k >= line.end ? line.width : Double(CTLineGetOffsetForStringIndex(ct, k, nil)) }
		func span(_ i: Int, _ j: Int) -> (Double, Double) { rtl ? (Paragraph.extent(ct, i, j) ?? (offset(i), offset(j))) : (offset(i), offset(j)) }
		let spaceX = spaces.map { let e = span($0, $0 + 1); return min(e.0, e.1) } // visual left edge of each opportunity
		let ns = full.string as NSString
		var runs: [PlacedRun] = []
		var i = line.start
		while i < line.end {
			if isSpace(utf16[i]) { i += 1; continue }
			let pi = pieceIndex(i)
			let pieceEnd = pi + 1 < runStarts.count ? runStarts[pi + 1] : line.end
			var j = i
			while j < line.end, j < pieceEnd, !isSpace(utf16[j]) { j += 1 }
			let (x0, x1) = span(i, j), x = min(x0, x1)
			let shift = Double(spaceX.filter { $0 < x }.count) * extra
			let st = pieces[pi].style, m = metrics(primaries[pi], st)
			runs.append(PlacedRun(text: ns.substring(with: NSRange(location: i, length: j - i)), style: st, x: x + shift, width: abs(x1 - x0), ascent: m.a, descent: m.d))
			i = j
		}
		return runs
	}
}
