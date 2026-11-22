// JSRuntime: runs a Remotion bundle inside JavaScriptCore — no Chrome, no WebKit page.
//
//  • Installs the native bridge `__mr` (file/URL resolution, fetch, fonts, clock, logging) and the
//    browser prelude (Resources/prelude.js).
//  • Loads the bundle the same way index.html does (inline globals, then bundle.js; webpack chunks are
//    loaded on demand through <script> elements handled by the prelude).
//  • Drives the event loop one task at a time (microtasks drain between tasks, like a browser) until
//    Remotion reports `remotion_renderReady`.
//  • Per frame: `remotion_setFrame(f)`, settle, collect audio assets, snapshot the element tree.
import Foundation
import JavaScriptCore
import ImageIO
import CryptoKit

final class JSRuntime {
	let ctx: JSContext
	let bundleDir: URL
	let origin = "http://localhost:3000"
	private(set) var fonts: [[String: Any]] = [] // newly registered faces, drained by the caller
	private(set) var lastError: String?
	let cacheDir: URL
	private let clock0 = DispatchTime.now().uptimeNanoseconds

	init(bundleDir: URL) throws {
		self.bundleDir = bundleDir
		cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MetalReel", isDirectory: true)
		try? FileManager.default.createDirectory(at: cacheDir.appendingPathComponent("http"), withIntermediateDirectories: true)
		guard let vm = JSVirtualMachine(), let c = JSContext(virtualMachine: vm) else { throw RuntimeError("JavaScriptCore unavailable") }
		ctx = c
		ctx.name = "MetalReel"
		ctx.exceptionHandler = { [weak self] _, exc in
			let msg = exc?.toString() ?? "?"
			let stack = exc?.objectForKeyedSubscript("stack")?.toString() ?? ""
			self?.lastError = msg
			log("  [js] uncaught: \(msg)\n\(stack.split(separator: "\n").prefix(6).map { "      " + $0 }.joined(separator: "\n"))")
		}
		installBridge()
		guard let preludeURL = Bundle.module.url(forResource: "prelude", withExtension: "js", subdirectory: "Resources"),
		      let prelude = try? String(contentsOf: preludeURL, encoding: .utf8) else { throw RuntimeError("prelude.js missing from resources") }
		ctx.evaluateScript(prelude, withSourceURL: URL(string: "metalreel://prelude.js"))
		if let e = lastError { throw RuntimeError("prelude failed: \(e)") }
	}

	struct RuntimeError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

	// MARK: native bridge
	private func installBridge() {
		let mr = JSValue(newObjectIn: ctx)!
		func set(_ name: String, _ block: Any) { mr.setObject(block, forKeyedSubscript: name as NSString) }
		let quiet = ProcessInfo.processInfo.environment["METALREEL_JS_LOG"] == nil
		set("log", { (level: String, msg: String) in
			if quiet && (level == "log" || level == "info" || level == "debug") { return }
			log("  [js \(level)] \(msg.prefix(2000))")
		} as @convention(block) (String, String) -> Void)
		set("now", { [clock0] in Double(DispatchTime.now().uptimeNanoseconds - clock0) / 1e6 } as @convention(block) () -> Double)
		set("origin", { [origin] in origin } as @convention(block) () -> String)
		set("cpuCount", { Double(ProcessInfo.processInfo.activeProcessorCount) } as @convention(block) () -> Double)
		set("readText", { (p: String) -> Any in (try? String(contentsOfFile: p, encoding: .utf8)) ?? NSNull() } as @convention(block) (String) -> Any)
		set("readBase64", { (p: String) -> String in (try? Data(contentsOf: URL(fileURLWithPath: p)))?.base64EncodedString() ?? "" } as @convention(block) (String) -> String)
		set("writeTemp", { [cacheDir] (b64: String, ext: String) -> String in
			let d = Data(base64Encoded: b64) ?? Data()
			let u = cacheDir.appendingPathComponent("http").appendingPathComponent(Insecure.SHA1.hash(data: d).map { String(format: "%02x", $0) }.joined() + ext)
			if !FileManager.default.fileExists(atPath: u.path) { try? d.write(to: u) }
			return u.path
		} as @convention(block) (String, String) -> String)
		set("resolve", { [weak self] (u: String) -> Any in self?.resolve(u) ?? NSNull() } as @convention(block) (String) -> Any)
		set("fetch", { [weak self] (u: String, method: String) -> Any in
			guard let self else { return NSNull() }
			guard let p = self.resolve(u) else { return ["status": 404, "path": NSNull(), "type": ""] }
			guard FileManager.default.fileExists(atPath: p) else { return ["status": 404, "path": NSNull(), "type": ""] }
			return ["status": 200, "path": p, "type": JSRuntime.mime(p)]
		} as @convention(block) (String, String) -> Any)
		set("imageSize", { (p: String) -> Any in
			guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
			      let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double else { return NSNull() }
			return [w, h]
		} as @convention(block) (String) -> Any)
		set("evalFile", { [weak self] (p: String, name: String) -> Bool in
			guard let self, let src = try? String(contentsOfFile: p, encoding: .utf8) else { log("  [warn] script not found: \(p)"); return false }
			self.ctx.evaluateScript(src, withSourceURL: URL(fileURLWithPath: p)); return true
		} as @convention(block) (String, String) -> Bool)
		set("evalScript", { [weak self] (src: String, name: String) in self?.ctx.evaluateScript(src, withSourceURL: URL(string: "metalreel://" + name)) } as @convention(block) (String, String) -> Void)
		set("registerFont", { [weak self] (family: String, path: String, weight: String, style: String, range: String) in
			self?.fonts.append(["family": family, "path": path, "w": weight, "s": style, "u": range])
		} as @convention(block) (String, String, String, String, String) -> Void)
		ctx.setObject(mr, forKeyedSubscript: "__mr" as NSString)
	}

	/// URL → local file. Bundle origin → bundle dir (public/ is a symlink inside it); file:// → path;
	/// http(s) elsewhere → downloaded once into ~/Library/Caches/MetalReel/http.
	func resolve(_ u: String) -> String? {
		if u.hasPrefix("/") { return resolve(origin + u) }
		if u.hasPrefix(origin) || u.hasPrefix("http://127.0.0.1:3000") || u.hasPrefix("http://localhost:") {
			guard let url = URL(string: u) else { return nil }
			let rel = url.path.removingPercentEncoding ?? url.path
			let p = bundleDir.appendingPathComponent(rel == "/" ? "index.html" : String(rel.dropFirst()))
			return p.resolvingSymlinksInPath().path
		}
		if u.hasPrefix("file://") { return URL(string: u)?.path ?? String(u.dropFirst(7)) }
		if u.hasPrefix("http://") || u.hasPrefix("https://") {
			let key = Insecure.SHA1.hash(data: Data(u.utf8)).map { String(format: "%02x", $0) }.joined()
			let ext = URL(string: u).map { $0.pathExtension }.flatMap { $0.isEmpty ? nil : "." + $0 } ?? ""
			let dest = cacheDir.appendingPathComponent("http").appendingPathComponent(key + ext)
			if FileManager.default.fileExists(atPath: dest.path) { return dest.path }
			guard let url = URL(string: u) else { return nil }
			let sem = DispatchSemaphore(value: 0); var ok = false
			let task = URLSession.shared.downloadTask(with: url) { tmp, resp, _ in
				if let tmp, let http = resp as? HTTPURLResponse, http.statusCode == 200 { ok = (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil }
				sem.signal()
			}
			task.resume(); _ = sem.wait(timeout: .now() + 60)
			return ok ? dest.path : nil
		}
		return nil
	}
	static func mime(_ p: String) -> String {
		["woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf", "otf": "font/otf", "json": "application/json", "js": "application/javascript", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
		 "webp": "image/webp", "svg": "image/svg+xml", "mp4": "video/mp4", "mov": "video/quicktime", "mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4", "css": "text/css", "txt": "text/plain"][(p as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
	}

	func drainFonts() -> [[String: Any]] { let f = fonts; fonts.removeAll(); return f }

	// MARK: event loop
	private lazy var step = ctx.objectForKeyedSubscript("__mr_step")!
	private var ready: Bool { ctx.objectForKeyedSubscript("remotion_renderReady")?.toBool() ?? false }
	/// Run the event loop until `done()` holds with no immediate work left (or the timeout expires).
	func settle(timeout: Double = 120, label: String, until done: () -> Bool) throws {
		let t0 = Date(); var steps = 0
		while true {
			let r = step.call(withArguments: [])!.toDouble()
			if r == 0 { steps += 1; if steps > 5_000_000 { throw RuntimeError("\(label): event loop never went idle") }; continue }
			if let cancelled = ctx.objectForKeyedSubscript("remotion_cancelledError"), !cancelled.isUndefined, !cancelled.isNull { throw RuntimeError("\(label): render cancelled: \(cancelled.toString() ?? "?")") }
			if done() { return }
			if Date().timeIntervalSince(t0) > timeout { throw RuntimeError("\(label): timed out after \(Int(timeout)) s (delayRender handles: \(pendingHandles()))") }
			if r < 0 { usleep(200) } else { usleep(useconds_t(min(r, 2) * 1000)) } // waiting on a timer
		}
	}
	func settleReady(label: String) throws { try settle(label: label) { ready } }
	func pendingHandles() -> String {
		ctx.evaluateScript("JSON.stringify(Object.values(window.remotion_delayRenderTimeouts ?? {}).map(h => h.label).slice(0, 5))")?.toString() ?? "?"
	}
	/// Await a JS promise by running the loop.
	func awaitJS(_ expr: String, label: String, timeout: Double = 120) throws -> JSValue {
		ctx.evaluateScript("globalThis.__mr_res = undefined; Promise.resolve(\(expr)).then(v => { globalThis.__mr_res = {ok: true, v} }, e => { globalThis.__mr_res = {ok: false, e: String(e && e.stack || e)} })")
		try settle(timeout: timeout, label: label) { !(ctx.objectForKeyedSubscript("__mr_res")?.isUndefined ?? true) }
		let r = ctx.objectForKeyedSubscript("__mr_res")!
		guard r.objectForKeyedSubscript("ok").toBool() else { throw RuntimeError("\(label): \(r.objectForKeyedSubscript("e").toString() ?? "?")") }
		return r.objectForKeyedSubscript("v")
	}

	// MARK: bundle
	struct Composition { let id: String; let width: Int; let height: Int; let fps: Int; let durationInFrames: Int; let serializedProps: String }

	/// Evaluate index.html's scripts in order (inline globals, then bundle.js).
	func loadBundle(inputProps: String, initialFrame: Int) throws {
		// globals Remotion expects from its renderer (same values @remotion/renderer injects into Chrome)
		let g: [String: Any] = ["remotion_puppeteerTimeout": 60000, "remotion_isMainTab": true, "remotion_mediaCacheSizeInBytes": 1e9, "remotion_initialMemoryAvailable": 8e9,
			"remotion_sampleRate": 48000, "remotion_inputProps": inputProps, "remotion_initialFrame": initialFrame, "remotion_attempt": 1, "remotion_proxyPort": 3000,
			"remotion_audioEnabled": true, "remotion_videoEnabled": true, "remotion_logLevel": "warn", "remotion_isMetalReel": true]
		for (k, v) in g { ctx.setObject(v, forKeyedSubscript: k as NSString) }
		let html = try String(contentsOf: bundleDir.appendingPathComponent("index.html"), encoding: .utf8)
		let container = "<div id=\"video-container\"></div>"
		ctx.evaluateScript("(() => { const d = document.createElement('div'); d.id = 'video-container'; document.body.appendChild(d); })()")
		_ = container
		let re = try NSRegularExpression(pattern: "<script([^>]*)>([\\s\\S]*?)</script>")
		for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
			let attrs = String(html[Range(m.range(at: 1), in: html)!]), body = String(html[Range(m.range(at: 2), in: html)!])
			if let sm = attrs.range(of: "src=\"([^\"]+)\"", options: .regularExpression) {
				let src = String(attrs[sm]).dropFirst(5).dropLast()
				ctx.evaluateScript("(() => { const s = document.createElement('script'); s.src = \(json(String(src))); document.body.appendChild(s); })()")
				try settle(label: "loading \(src)") { !(ctx.evaluateScript("__mr_hasImmediateWork()")?.toBool() ?? false) }
			} else if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				ctx.evaluateScript(body, withSourceURL: URL(string: "metalreel://index.html"))
			}
		}
		if let e = lastError { throw RuntimeError("bundle failed to load: \(e)") }
		guard ctx.objectForKeyedSubscript("remotion_setBundleMode")?.isObject ?? false else { throw RuntimeError("not a Remotion bundle (remotion_setBundleMode missing)") }
	}

	/// Chrome-free selectComposition(): evaluate the root, run calculateMetadata().
	func selectComposition(_ id: String) throws -> Composition {
		ctx.evaluateScript("remotion_setBundleMode({type: 'evaluation'})")
		try settleReady(label: "evaluating root")
		let v = try awaitJS("remotion_calculateComposition(\(json(id)))", label: "calculateMetadata(\(id))")
		func i(_ k: String) -> Int { Int(v.objectForKeyedSubscript(k).toInt32()) }
		return Composition(id: id, width: i("width"), height: i("height"), fps: i("fps"), durationInFrames: i("durationInFrames"),
		                   serializedProps: v.objectForKeyedSubscript("serializedResolvedPropsWithCustomSchema").toString() ?? "{}")
	}
	func listCompositions() throws -> [String] {
		ctx.evaluateScript("remotion_setBundleMode({type: 'evaluation'})")
		try settleReady(label: "evaluating root")
		return (ctx.evaluateScript("remotion_getCompositionNames()")?.toArray() as? [String]) ?? []
	}

	func mount(_ c: Composition) throws {
		let mode: [String: Any] = ["type": "composition", "compositionName": c.id, "serializedResolvedPropsWithSchema": c.serializedProps,
			"compositionDurationInFrames": c.durationInFrames, "compositionFps": c.fps, "compositionHeight": c.height, "compositionWidth": c.width,
			"compositionDefaultCodec": "h264", "compositionDefaultOutName": "out", "compositionDefaultVideoImageFormat": "jpeg",
			"compositionDefaultPixelFormat": "yuv420p", "compositionDefaultProResProfile": NSNull(), "compositionDefaultSampleRate": 48000]
		ctx.objectForKeyedSubscript("remotion_setBundleMode")!.call(withArguments: [mode])
		try settleReady(label: "mounting \(c.id)")
	}

	struct Frame { let tree: String; let assets: [[String: Any]]; let changed: Bool }
	private lazy var setFrameFn = ctx.objectForKeyedSubscript("remotion_setFrame")!
	private lazy var snapshotFn = ctx.objectForKeyedSubscript("__mr_snapshot")!
	private lazy var collectFn = ctx.objectForKeyedSubscript("remotion_collectAssets")
	private var lastTree = ""

	func renderFrame(_ f: Int, compId: String) throws -> Frame {
		setFrameFn.call(withArguments: [f, compId, 1])
		try settleReady(label: "frame \(f)")
		var assets: [[String: Any]] = []
		if let c = collectFn, c.isObject, let raw = c.call(withArguments: [])?.toArray() as? [[String: Any]] {
			for a in raw where (a["type"] as? String) == "audio" || (a["type"] as? String) == "video" {
				guard (a["frame"] as? Int) == f || (a["frame"] as? Double).map({ Int($0) }) == f else { continue }
				let src = (a["src"] as? String).flatMap { resolve($0) } ?? ""
				assets.append(["id": a["id"] ?? "", "src": src, "frame": f, "v": a["volume"] ?? 1, "mf": a["mediaFrame"] ?? 0, "pr": a["playbackRate"] ?? 1, "si": a["audioStreamIndex"] ?? 0])
			}
		}
		let dirty = ctx.evaluateScript("__mr_isDirty()")?.toBool() ?? true
		if !dirty && !lastTree.isEmpty { return Frame(tree: lastTree, assets: assets, changed: false) }
		let tree = snapshotFn.call(withArguments: ["#video-container"])?.toString() ?? "null"
		let changed = tree != lastTree
		lastTree = tree
		return Frame(tree: tree, assets: assets, changed: changed)
	}

	func json(_ s: String) -> String { String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!.dropFirst().dropLast().description }
}
