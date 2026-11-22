// Encoder: frames (CIImage) → VideoToolbox H.264/HEVC, plus Remotion's audio assets mixed with AVFoundation.
//
// Shared by both front ends (hybrid: Chrome display list on stdin; native: JavaScriptCore + Yoga).
//  1. Each frame is rendered by Core Image straight into an IOSurface-backed CVPixelBuffer from the
//     encoder's pool (zero copy: GPU → VideoToolbox), several frames in flight.
//  2. Audio: Remotion registers audio/video assets per frame (src, volume, media frame, playback rate).
//     We rebuild the clip list exactly like Remotion's calculateAssetPositions() and mix with AVAudioMix.
//  3. Video + audio are muxed without re-encoding.
import Foundation
import AVFoundation
import CoreImage
import Metal

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func fail(_ s: String) -> Never { log("error: " + s); exit(1) }

final class FrameEncoder {
	let W: Int, H: Int, fps: Int
	let out: URL
	private let ctx: CIContext
	private let writer: AVAssetWriter
	private let input: AVAssetWriterInput
	private let adaptor: AVAssetWriterInputPixelBufferAdaptor
	private let tmpVideo: URL, tmpAudio: URL
	private let queue = DispatchQueue(label: "ci-render", qos: .userInitiated, attributes: .concurrent)
	private let inFlight: Int
	private var pending: [Pending] = []
	private var assetsPerFrame: [[[String: Any]]] = []
	private(set) var count = 0
	let started = Date()

	final class Pending { let done = DispatchSemaphore(value: 0); let pb: CVPixelBuffer; let i: Int; let keep: [CMSampleBuffer]
		init(pb: CVPixelBuffer, i: Int, keep: [CMSampleBuffer]) { self.pb = pb; self.i = i; self.keep = keep } }
	private static let colorTags: [CFString: CFString] = [kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
		kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2]

	init(ctx: CIContext, width: Int, height: Int, fps: Int, out: URL, codec: String = "h264", bitrate: String? = nil, inFlight: Int = 6) throws {
		self.ctx = ctx; W = width; H = height; self.fps = fps; self.out = out; self.inFlight = inFlight
		let hevc = codec == "hevc"
		let bps: Int = { guard var s = bitrate else { return width * height >= 1920 * 1080 ? 6_000_000 : 3_000_000 }; var m = 1.0
			if s.hasSuffix("M") { m = 1e6; s.removeLast() } else if s.hasSuffix("k") { m = 1e3; s.removeLast() }; return Int((Double(s) ?? 6) * m) }()
		tmpVideo = out.deletingLastPathComponent().appendingPathComponent("." + out.lastPathComponent + ".video.mp4")
		tmpAudio = out.deletingLastPathComponent().appendingPathComponent("." + out.lastPathComponent + ".audio.m4a")
		try? FileManager.default.removeItem(at: tmpVideo)
		writer = try AVAssetWriter(outputURL: tmpVideo, fileType: .mp4)
		var comp: [String: Any] = [AVVideoAverageBitRateKey: bps, AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 8, AVVideoAllowFrameReorderingKey: true]
		if !hevc { comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel; comp[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC }
		input = AVAssetWriterInput(mediaType: .video, outputSettings: [
			AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
			AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
			AVVideoCompressionPropertiesKey: comp,
		])
		input.expectsMediaDataInRealTime = false
		adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
			kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
		])
		writer.add(input)
		guard writer.startWriting() else { throw NSError(domain: "metalreel", code: 1, userInfo: [NSLocalizedDescriptionKey: "writer: \(writer.error?.localizedDescription ?? "?")"]) }
		writer.startSession(atSourceTime: .zero)
	}

	/// Queue one frame. `keep` holds decoded video sample buffers alive until the GPU has read them.
	func append(_ img: CIImage, keep: [CMSampleBuffer], assets: [[String: Any]]) {
		assetsPerFrame.append(assets)
		var pbO: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pbO); let pb = pbO!
		CVBufferSetAttachments(pb, FrameEncoder.colorTags as CFDictionary, .shouldPropagate)
		let dest = CIRenderDestination(pixelBuffer: pb); dest.colorSpace = SRGB
		let p = Pending(pb: pb, i: count, keep: keep)
		pending.append(p)
		let ctx = self.ctx
		// Core Image's GPU preparation costs a few ms of CPU per frame: run several in parallel, append in order.
		queue.async { do { let t = try ctx.startTask(toRender: img, to: dest); _ = try t.waitUntilCompleted() } catch { fail("render: \(error)") }; p.done.signal() }
		if pending.count >= inFlight { drain(pending.removeFirst()) }
		count += 1
		if count % 600 == 0 {
			if ProcessInfo.processInfo.thermalState == .critical { fail("Mac is critically hot; stopping") }
			log(String(format: "  encode: %d frames, %.1f fps", count, Double(count) / Date().timeIntervalSince(started)))
		}
	}
	private func drain(_ p: Pending) {
		p.done.wait()
		while !input.isReadyForMoreMediaData { usleep(200) }
		if !adaptor.append(p.pb, withPresentationTime: CMTime(value: CMTimeValue(p.i), timescale: CMTimeScale(fps))) { fail("append: \(writer.error?.localizedDescription ?? "?")") }
	}

	struct Result { let frames: Int; let seconds: Double; let videoSeconds: Double; let audioClips: Int; let bytes: Int }

	/// Finish video, mix audio, mux. Returns timing info.
	func finish(audio: Bool = true) async throws -> Result {
		for p in pending { drain(p) }; pending.removeAll()
		input.markAsFinished()
		await writer.finishWriting()
		if writer.status != .completed { throw NSError(domain: "metalreel", code: 2, userInfo: [NSLocalizedDescriptionKey: "write failed: \(writer.error?.localizedDescription ?? "?")"]) }
		let videoSeconds = Date().timeIntervalSince(started)
		let clips = audio ? clipsFromAssets() : []
		let hasAudio = clips.isEmpty ? false : try await mix(clips)
		try? FileManager.default.removeItem(at: out)
		if hasAudio {
			let comp = AVMutableComposition()
			let va = AVURLAsset(url: tmpVideo), sa = AVURLAsset(url: tmpAudio)
			let vt = try await va.loadTracks(withMediaType: .video).first!, st = try await sa.loadTracks(withMediaType: .audio).first!
			let vDur = try await va.load(.duration)
			let vc = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
			try vc.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vt, at: .zero)
			let sc = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
			try sc.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(vDur, try await sa.load(.duration))), of: st, at: .zero)
			let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
			try await ex.export(to: out, as: .mp4)
			try? FileManager.default.removeItem(at: tmpVideo); try? FileManager.default.removeItem(at: tmpAudio)
		} else {
			try FileManager.default.moveItem(at: tmpVideo, to: out)
		}
		let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
		return Result(frames: count, seconds: Date().timeIntervalSince(started), videoSeconds: videoSeconds, audioClips: hasAudio ? clips.count : 0, bytes: bytes)
	}

	// MARK: audio — equivalent of Remotion's calculateAssetPositions()
	struct Clip { let src: String; let start: Int; var duration: Int; let trimFrames: Double; var volumes: [Double]; let rate: Double; let stream: Int }
	private func clipsFromAssets() -> [Clip] {
		var clips: [Clip] = [], open: [String: Int] = [:]
		for (f, assets) in assetsPerFrame.enumerated() {
			let now = Set(assets.compactMap { $0["id"] as? String })
			for (id, ci) in open where !now.contains(id) { clips[ci].duration = f - clips[ci].start; open.removeValue(forKey: id) }
			var seen = Set<String>()
			for a in assets {
				guard let id = a["id"] as? String, !seen.contains(id), let src = a["src"] as? String else { continue }
				seen.insert(id)
				let v = (a["v"] as? Double) ?? 1
				if let ci = open[id] { clips[ci].volumes.append(v) } else {
					open[id] = clips.count
					clips.append(Clip(src: src, start: f, duration: 0, trimFrames: (a["mf"] as? Double) ?? 0, volumes: [v], rate: (a["pr"] as? Double) ?? 1, stream: (a["si"] as? Int) ?? 0))
				}
			}
		}
		for (_, ci) in open { clips[ci].duration = assetsPerFrame.count - clips[ci].start }
		return clips.filter { $0.duration > 0 }
	}
	private func mix(_ clips: [Clip]) async throws -> Bool {
		let comp = AVMutableComposition()
		var params: [AVMutableAudioMixInputParameters] = []
		let ts = CMTimeScale(fps)
		for p in clips {
			guard p.src.hasPrefix("/"), FileManager.default.fileExists(atPath: p.src) else { log("  [warn] audio source is not a local file, skipped: \(p.src)"); continue }
			let a = AVURLAsset(url: URL(fileURLWithPath: p.src))
			let tracks = try await a.loadTracks(withMediaType: .audio)
			guard p.stream < tracks.count else { continue }
			if abs(p.rate - 1) > 1e-6 { log("  [warn] playbackRate \(p.rate): pitch is not preserved") }
			guard let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
			let mediaStart = CMTime(seconds: p.trimFrames / Double(fps), preferredTimescale: 48000)
			let at = CMTime(value: CMTimeValue(p.start), timescale: ts)
			let dur = CMTime(value: CMTimeValue(p.duration), timescale: ts)
			let srcDur = try await a.load(.duration)
			let mediaDur = CMTimeMinimum(CMTimeMultiplyByFloat64(dur, multiplier: p.rate), srcDur - mediaStart)
			guard mediaDur.seconds > 0 else { continue }
			try t.insertTimeRange(CMTimeRange(start: mediaStart, duration: mediaDur), of: tracks[p.stream], at: at)
			if abs(p.rate - 1) > 1e-6 { t.scaleTimeRange(CMTimeRange(start: at, duration: mediaDur), toDuration: dur) }
			let prm = AVMutableAudioMixInputParameters(track: t)
			if Set(p.volumes).count == 1 { prm.setVolume(Float(p.volumes[0]), at: .zero) } else {
				prm.setVolume(Float(p.volumes[0]), at: at)
				for j in 0..<(p.volumes.count - 1) where p.volumes[j] != p.volumes[j + 1] {
					prm.setVolumeRamp(fromStartVolume: Float(p.volumes[j]), toEndVolume: Float(p.volumes[j + 1]), timeRange: CMTimeRange(start: at + CMTime(value: CMTimeValue(j), timescale: ts), duration: CMTime(value: 1, timescale: ts)))
				}
			}
			params.append(prm)
		}
		guard !params.isEmpty else { return false }
		let mixer = AVMutableAudioMix(); mixer.inputParameters = params
		let r = try AVAssetReader(asset: comp)
		let o = AVAssetReaderAudioMixOutput(audioTracks: try await comp.loadTracks(withMediaType: .audio), audioSettings: [
			AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
			AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
		])
		o.audioMix = mixer; r.add(o)
		r.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: CMTimeValue(count), timescale: ts))
		try? FileManager.default.removeItem(at: tmpAudio)
		let sw = try AVAssetWriter(outputURL: tmpAudio, fileType: .m4a)
		let si = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000])
		si.expectsMediaDataInRealTime = false; sw.add(si)
		r.startReading(); sw.startWriting(); sw.startSession(atSourceTime: .zero)
		while let sb = o.copyNextSampleBuffer() { while !si.isReadyForMoreMediaData { usleep(100) }; si.append(sb) }
		si.markAsFinished(); await sw.finishWriting()
		if sw.status != .completed { log("  [warn] audio write failed: \(sw.error?.localizedDescription ?? "?")"); return false }
		return true
	}
}

/// Metal-backed Core Image context shared by the painter and the encoder.
func makeCIContext(halfFloat: Bool = true) -> CIContext {
	let dev = MTLCreateSystemDefaultDevice()!
	return CIContext(mtlDevice: dev, options: [.workingColorSpace: SRGB, .workingFormat: halfFloat ? CIFormat.RGBAh : CIFormat.RGBA8, .cacheIntermediates: false])
}
