// WebKit fallback: anything the native painter can't draw (SVG, clip-path, mask, drop-shadow, …) is
// rendered by WebKit — only that element, at its exact on-screen transform — and returned as a PNG.
// Results are cached by content, so a static logo or an SVG that repeats is rendered once.
import Foundation
import AppKit
import WebKit
import AVFoundation
import CryptoKit

final class WebFallback: NSObject, WKNavigationDelegate {
	private var web: WKWebView!
	private var window: NSWindow!
	private var loaded = false
	private let dir: URL
	private(set) var renders = 0, hits = 0
	private var memo: [String: String] = [:]

	override init() {
		dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MetalReel/fallback", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		super.init()
		_ = NSApplication.shared
		NSApp.setActivationPolicy(.prohibited)
		let cfg = WKWebViewConfiguration()
		cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
		cfg.suppressesIncrementalRendering = true
		web = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: cfg)
		web.setValue(false, forKey: "drawsBackground")
		web.navigationDelegate = self
		// an off-screen window keeps WebKit painting (views outside a window are throttled)
		window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 64, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = web
		window.orderBack(nil)
	}

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loaded = true }
	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loaded = true }

	private func spin(_ cond: () -> Bool, timeout: Double = 15) -> Bool {
		let t0 = Date()
		while !cond() { if Date().timeIntervalSince(t0) > timeout { return false }; RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }
		return true
	}

	/// Render `html` (one element) through `matrix` (element-local → canvas px) into a size-px PNG.
	func render(html: String, inherited c: Computed, matrix m: CGAffineTransform, opacity: Double, size: CGSize, fontFaces: String) -> String? {
		let wrapper = "position:absolute;left:0;top:0;transform-origin:0 0;transform:matrix(\(m.a),\(m.b),\(m.c),\(m.d),\(m.tx),\(m.ty));opacity:\(opacity);" +
			"font-family:\(c.fontFamily);font-size:\(c.fontSize)px;font-weight:\(Int(c.fontWeight));font-style:\(c.italic ? "italic" : "normal");color:\(CSS.computed(c.color));letter-spacing:\(c.letterSpacing)px;text-align:\(c.textAlign);white-space:\(c.whiteSpace)"
		let page = "<!doctype html><html><head><meta charset=utf-8><style>\(fontFaces) html,body{margin:0;padding:0;background:transparent;overflow:hidden;width:\(Int(size.width))px;height:\(Int(size.height))px} *{box-sizing:border-box}</style></head><body><div style=\"\(wrapper)\">\(html)</div></body></html>"
		let key = Insecure.SHA1.hash(data: Data((page + "\(size)").utf8)).map { String(format: "%02x", $0) }.joined()
		if let p = memo[key] { hits += 1; return p }
		let png = dir.appendingPathComponent(key + ".png")
		if FileManager.default.fileExists(atPath: png.path) { memo[key] = png.path; hits += 1; return png.path }
		let htmlURL = dir.appendingPathComponent(key + ".html")
		try? page.write(to: htmlURL, atomically: true, encoding: .utf8)
		window.setContentSize(size); web.frame = CGRect(origin: .zero, size: size)
		loaded = false
		web.loadFileURL(htmlURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
		guard spin({ loaded }) else { return nil }
		// wait for web fonts + one paint
		var fontsReady = false
		web.evaluateJavaScript("document.fonts.ready.then(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))).then(() => 1)") { _, _ in fontsReady = true }
		_ = spin({ fontsReady }, timeout: 5)
		var out: CGImage?, done = false
		let sc = WKSnapshotConfiguration(); sc.rect = CGRect(origin: .zero, size: size); sc.afterScreenUpdates = true; sc.snapshotWidth = NSNumber(value: Double(size.width))
		web.takeSnapshot(with: sc) { img, _ in
			if let img { var r = CGRect(origin: .zero, size: img.size); out = img.cgImage(forProposedRect: &r, context: nil, hints: nil) }
			done = true
		}
		guard spin({ done }), let cg = out else { return nil }
		// normalize to exactly size px, sRGB, premultiplied
		let w = Int(size.width), h = Int(size.height)
		guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: SRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
		ctx.interpolationQuality = .high
		ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
		guard let img = ctx.makeImage(), let dst = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
		try? FileManager.default.removeItem(at: htmlURL)
		renders += 1
		memo[key] = png.path
		return png.path
	}
}

/// Box tree → HTML for the WebKit fallback (the element and its subtree, styles inline).
enum Markup {
	static func kebab(_ k: String) -> String {
		if k.hasPrefix("--") { return k }
		var s = ""; for ch in k { if ch.isUppercase { s += "-" + ch.lowercased() } else { s.append(ch) } }
		if s.hasPrefix("webkit-") || s.hasPrefix("moz-") || s.hasPrefix("ms-") { s = "-" + s }
		return s
	}
	static func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
	static func element(_ b: Box, size: CGSize, root: Bool) -> String {
		if let t = b.text { return esc(t) }
		var style = b.style
		if root {
			for k in ["position", "top", "left", "right", "bottom", "inset", "margin", "marginTop", "marginLeft", "marginRight", "marginBottom", "transform", "translate", "rotate", "scale", "opacity", "flex", "flexGrow", "flexShrink", "flexBasis", "alignSelf"] { style[k] = nil }
			style["position"] = "relative"; style["width"] = "\(size.width)px"; style["height"] = "\(size.height)px"
		}
		let css = style.map { "\(kebab($0.key)):\($0.value)" }.joined(separator: ";")
		if var m = b.markup {
			// inject the computed size/style onto the outer tag of serialized markup (svg)
			if root, let close = m.firstIndex(of: ">") {
				let head = m[..<close]
				let cleaned = head.replacingOccurrences(of: " style=\"[^\"]*\"", with: "", options: .regularExpression)
				m = cleaned + " style=\"\(esc(css))\"" + m[close...]
			}
			return m
		}
		let tag = b.tag.hasPrefix("#") ? "div" : b.tag
		var attrs = ""
		for (k, v) in b.attrs { if k == "video" || k == "time" || k == "toneMapped" { continue }; attrs += " \(k)=\"\(esc("\(k == "src" ? "file://" : "")\(v)"))\"" }
		let inner = b.children.map { element($0, size: .zero, root: false) }.joined()
		return "<\(tag)\(attrs) style=\"\(esc(css))\">\(inner)</\(tag)>"
	}
}

func videoNaturalSize(_ path: String) -> CGSize {
	let a = AVURLAsset(url: URL(fileURLWithPath: path))
	guard let t = a.tracks(withMediaType: .video).first else { return CGSize(width: 1920, height: 1080) }
	let s = t.naturalSize.applying(t.preferredTransform)
	return CGSize(width: abs(s.width), height: abs(s.height))
}
