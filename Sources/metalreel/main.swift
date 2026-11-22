// metalreel — render Remotion compositions with Apple's native engines.
//
//   metalreel render --bundle <dir> --comp <id> [--out x.mp4] [--frames a-b] [--props '{...}']
//                    [--codec h264|hevc] [--bitrate 6M] [--still N --png out.png] [--no-webkit]
//        native mode: JavaScriptCore + Yoga + Core Text + Metal + VideoToolbox. No Chrome.
//   metalreel draw --out x.mp4 [--codec …] [--png-frame N --png out.png] < display-list.ndjson
//        hybrid mode back end: paints the display list that js/hybrid/extract.mjs pulls out of Chrome.
//   metalreel compositions --bundle <dir>
//
// The bundle is produced by Remotion's own bundler (see js/cli/metalreel.mjs, which also wires the
// react-dom alias for native mode).
import Foundation
import CoreImage

setvbuf(stdout, nil, _IOLBF, 0)
var args: [String: String] = [:]
var flags = Set<String>()
let argv = CommandLine.arguments
let command = argv.count > 1 ? argv[1] : "help"
do { var i = 2; while i < argv.count { if argv[i].hasPrefix("--") { let k = String(argv[i].dropFirst(2)); if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { args[k] = argv[i + 1]; i += 2 } else { flags.insert(k); i += 1 } } else { i += 1 } } }

/// Run async AVFoundation work to completion from synchronous code. The renderer stays on the real main
/// thread (8 MB stack, and WebKit requires it); Swift task threads only have 512 KB of stack.
func blocking<T>(_ f: @escaping () async throws -> T) throws -> T {
	var result: Result<T, Error>?
	let sem = DispatchSemaphore(value: 0)
	Task.detached { do { result = .success(try await f()) } catch { result = .failure(error) }; sem.signal() }
	sem.wait()
	return try result!.get()
}

func usage() -> Never {
	print("""
	usage:
	  metalreel render --bundle <dir> --comp <id> [--out x.mp4] [--frames a-b] [--props json] [--codec h264|hevc] [--bitrate 6M]
	                   [--still N --png out.png] [--no-webkit] [--dump-ops file.ndjson]
	  metalreel draw --out x.mp4 [--codec h264|hevc] [--bitrate 6M] [--png-frame N --png out.png]   (display list on stdin)
	  metalreel compositions --bundle <dir>
	""")
	exit(command == "help" || command == "--help" ? 0 : 1)
}

switch command {
case "render": try renderNative()
case "draw": try drawDisplayList()
case "compositions":
	guard let b = args["bundle"] else { usage() }
	let rt = try JSRuntime(bundleDir: URL(fileURLWithPath: b))
	try rt.loadBundle(inputProps: args["props"] ?? "{}", initialFrame: 0)
	for id in try rt.listCompositions() { print(id) }
default: usage()
}

// MARK: native mode
func renderNative() throws {
	guard let bundle = args["bundle"], let compId = args["comp"] else { usage() }
	let t0 = Date()
	let rt = try JSRuntime(bundleDir: URL(fileURLWithPath: bundle))
	JSRuntimeBridge.resolve = { rt.resolve($0) }
	try rt.loadBundle(inputProps: args["props"] ?? "{}", initialFrame: 0)
	let comp = try rt.selectComposition(compId)
	var first = 0, last = comp.durationInFrames - 1
	if let s = args["still"].flatMap(Int.init) { first = s; last = s }
	if let fr = args["frames"] { let p = fr.split(separator: "-").compactMap { Int($0) }; first = p[0]; last = p.count > 1 ? p[1] : p[0] }
	last = min(last, comp.durationInFrames - 1)
	try rt.mount(comp)
	let tBoot = Date().timeIntervalSince(t0)
	log("\(comp.id): \(comp.width)×\(comp.height) @ \(comp.fps) fps, frames \(first)–\(last) (\(last - first + 1)) — JavaScriptCore boot \(String(format: "%.2f", tBoot)) s")

	let ctx = makeCIContext()
	let fonts = FontRegistry(directory: args["fonts"].map { URL(fileURLWithPath: $0) })
	let painter = Painter(width: Double(comp.width), height: Double(comp.height), fonts: fonts)
	painter.ctx = ctx
	let front = NativeFrontEnd(width: Double(comp.width), height: Double(comp.height), fonts: fonts, fallback: flags.contains("no-webkit") ? nil : WebFallback())
	var dump: FileHandle? = nil
	if let d = args["dump-ops"] { FileManager.default.createFile(atPath: d, contents: nil); dump = FileHandle(forWritingAtPath: d) }

	var tJS = 0.0, tLayout = 0.0, tPaint = 0.0
	var lastOps: [[String: Any]] = []
	func produce(_ f: Int) throws -> ([[String: Any]], [[String: Any]]) {
		let a = Date()
		let fr = try rt.renderFrame(f, compId: comp.id)
		for face in rt.drainFonts() { front.addFont(face) }
		let b = Date(); tJS += b.timeIntervalSince(a)
		if let p = ProcessInfo.processInfo.environment["METALREEL_DUMP_TREE"] { try? fr.tree.write(toFile: p, atomically: true, encoding: .utf8) }
		if fr.changed || lastOps.isEmpty { lastOps = front.displayList(fr.tree) }
		tLayout += Date().timeIntervalSince(b)
		if let dump { dump.write((String(data: try JSONSerialization.data(withJSONObject: ["f": f, "ops": lastOps]), encoding: .utf8)! + "\n").data(using: .utf8)!) }
		return (lastOps, fr.assets)
	}

	if let png = args["png"] {
		let (ops, _) = try produce(first)
		let img = painter.frame(ops)
		try ctx.writePNGRepresentation(of: img, to: URL(fileURLWithPath: png), format: .RGBA8, colorSpace: SRGB)
		log("frame \(first) → \(png) (\(ops.count) ops)")
		Diagnostics.report(); return
	}
	let out = URL(fileURLWithPath: args["out"] ?? "\(comp.id).mp4")
	try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
	let enc = try FrameEncoder(ctx: ctx, width: comp.width, height: comp.height, fps: comp.fps, out: out, codec: args["codec"] ?? "h264", bitrate: args["bitrate"])
	for f in first...last {
		let (ops, assets) = try produce(f)
		let p0 = Date()
		painter.retained.removeAll(keepingCapacity: true)
		let img = painter.frame(ops)
		tPaint += Date().timeIntervalSince(p0)
		enc.append(img, keep: painter.retained, assets: assets)
	}
	let r = try blocking { try await enc.finish(audio: !flags.contains("muted")) }
	let total = Date().timeIntervalSince(t0)
	print(String(format: "DONE native %d frames in %.2f s (%.1f fps incl. boot %.2f s) → %@ %.1f MB, audio clips: %d | js %.2f s, layout %.2f s, paint-graph %.2f s, encode+audio %.2f s",
	             r.frames, total, Double(r.frames) / total, tBoot, out.path, Double(r.bytes) / 1e6, r.audioClips, tJS, tLayout, tPaint, r.seconds - tJS - tLayout - tPaint))
	if let fb = front.fallback, fb.renders + fb.hits > 0 { log("  WebKit fallback: \(fb.renders) renders, \(fb.hits) cache hits") }
	Diagnostics.report()
}

// MARK: hybrid mode back end (display list on stdin)
func drawDisplayList() throws {
	guard let outPath = args["out"] ?? args["png"] else { usage() }
	guard let headLine = readLine(), let head = try? JSONSerialization.jsonObject(with: Data(headLine.utf8)) as? [String: Any] else { fail("missing header line") }
	let W = (head["w"] as? Int) ?? 1080, H = (head["h"] as? Int) ?? 1920, FPS = (head["fps"] as? Int) ?? 30
	let ctx = makeCIContext(halfFloat: args["format"] != "8")
	let painter = Painter(width: Double(W), height: Double(H), fonts: FontRegistry(directory: args["fonts"].map { URL(fileURLWithPath: $0) }))
	painter.ctx = ctx
	func next() -> [String: Any]? {
		while let s = readLine(strippingNewline: true) {
			guard let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { continue }
			if d["ops"] == nil, let fl = d["fonts"] as? [[String: Any]] { for f in fl { painter.fonts.add(f) }; continue }
			return d
		}
		return nil
	}
	if let pf = args["png-frame"].flatMap(Int.init), let png = args["png"] {
		while let k = next() {
			if (k["f"] as? Int) == pf {
				try ctx.writePNGRepresentation(of: painter.frame(k["ops"] as! [[String: Any]]), to: URL(fileURLWithPath: png), format: .RGBA8, colorSpace: SRGB)
				log("frame \(pf) → \(png)"); return
			}
		}
		fail("frame not found")
	}
	let out = URL(fileURLWithPath: outPath)
	let enc = try FrameEncoder(ctx: ctx, width: W, height: H, fps: FPS, out: out, codec: args["codec"] ?? "h264", bitrate: args["bitrate"], inFlight: Int(args["parallel"] ?? "6") ?? 6)
	var tRead = 0.0
	while true {
		let a = Date(); guard let k = next() else { break }; tRead += Date().timeIntervalSince(a)
		painter.retained.removeAll(keepingCapacity: true)
		enc.append(painter.frame(k["ops"] as! [[String: Any]]), keep: painter.retained, assets: (k["a"] as? [[String: Any]]) ?? [])
	}
	let r = try blocking { try await enc.finish(audio: args["audio"] != "off") }
	print(String(format: "DONE hybrid %d frames in %.2f s (%.1f fps) → %@ %.1f MB, audio clips: %d (waiting for Chrome %.1f s)", r.frames, r.seconds, Double(r.frames) / r.seconds, out.path, Double(r.bytes) / 1e6, r.audioClips, tRead))
}
