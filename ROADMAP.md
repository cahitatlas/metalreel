# Roadmap

MetalReel's goal is to render every Remotion composition natively on Apple Silicon, without a browser.
This file is the public to-do list. Each item has a matching GitHub issue with the `roadmap` label;
the pinned [tracking issue](https://github.com/cahitatlas/metalreel/issues/22) lists them all. 👍 or comment on the ones you need, or pick one up (see [CONTRIBUTING.md](CONTRIBUTING.md)).

Estimates are rough guesses, not measurements.

## Why some things still need Chrome

Metal is only the paint engine. Native mode runs your JavaScript in JavaScriptCore, which has no browser APIs.
Everything a composition calls (DOM, CSS, text, video, fetch) has to be re-implemented on Apple's frameworks.
The common parts are done. The items below are not yet, so those compositions fall back to
[hybrid mode](README.md#two-modes) (Chrome produces the layout, Metal still paints and encodes).

## Native gaps

Ordered by how many real-world projects they unblock.

### Next

- [ ] **Web Audio for audio visualizations** (`useAudioData`, `visualizeAudio`, `getWaveformPortion`). Decode audio with AVFoundation and expose `AudioContext.decodeAudioData` through the bridge. Unblocks audiograms and music visualizers. *Estimate: 1–2 days.* ([#1](https://github.com/cahitatlas/metalreel/issues/1))
- [ ] **Measurement APIs** (`getBoundingClientRect`, `offsetWidth`/`offsetHeight`, `scrollWidth`, `@remotion/layout-utils` `measureText` / `fitText`). Feed Yoga and Core Text results back into the DOM shim. Unblocks auto-fitting titles and Code Hike–style animations. *Estimate: 2–3 days.* ([#2](https://github.com/cahitatlas/metalreel/issues/2))
- [ ] **Canvas 2D** (`<canvas>` with `CanvasRenderingContext2D` on Core Graphics / Metal). Unblocks canvas charts, particle effects and most of the work for the new `<Video>` component. *Estimate: about 1 week.* ([#3](https://github.com/cahitatlas/metalreel/issues/3))
- [ ] **`@remotion/media` `<Video>` / `<Audio>`** (the newer canvas and WebCodecs–based components). Map them to the existing VideoToolbox decoder. *Depends on canvas 2D.* ([#4](https://github.com/cahitatlas/metalreel/issues/4))
- [ ] **Stylesheets and `className`** (CSS files, CSS modules, Tailwind). A selector matcher and cascade in front of the existing inline-style path. *Estimate: about 1 week.* ([#5](https://github.com/cahitatlas/metalreel/issues/5))

### Later

- [ ] **3D models without WebGL:** a native `<Model src="model.glb">`-style component rendered with SceneKit / RealityKit on Metal, covering product spins and turntables. *Estimate: about 1 week.* ([#6](https://github.com/cahitatlas/metalreel/issues/6))
- [ ] **WebGL / three.js / `@remotion/three`:** a WebGL implementation on Metal (ANGLE-style). *Hard; several weeks.* ([#7](https://github.com/cahitatlas/metalreel/issues/7))
- [ ] **Lottie** (`@remotion/lottie`): draw Lottie JSON natively instead of through the SVG renderer. *Estimate: about 1 week.* ([#8](https://github.com/cahitatlas/metalreel/issues/8))
- [ ] **`@remotion/skia`:** CanvasKit needs WebGL or a Skia build for Metal. *Hard.* ([#9](https://github.com/cahitatlas/metalreel/issues/9))
- [ ] **Maps** (Mapbox GL and similar): needs WebGL. *Follows the WebGL item.* ([#7](https://github.com/cahitatlas/metalreel/issues/7))

### Small CSS gaps

Each is a few hours to a day.

- [ ] `text-decoration` (underline, line-through, overline, decoration color and thickness) ([#10](https://github.com/cahitatlas/metalreel/issues/10))
- [ ] `-webkit-text-stroke` (outlined text) ([#11](https://github.com/cahitatlas/metalreel/issues/11))
- [ ] Per-corner `border-radius` (today one radius is used for all corners) ([#12](https://github.com/cahitatlas/metalreel/issues/12))
- [ ] Real 3D transforms: `perspective`, `rotateX` / `rotateY`, `transform-style: preserve-3d` (today approximated as 2D) ([#13](https://github.com/cahitatlas/metalreel/issues/13))
- [ ] `display: inline-block` flow ([#14](https://github.com/cahitatlas/metalreel/issues/14))
- [ ] The rest of CSS grid: explicit placement, spans, `auto-fill` / `auto-fit`, named areas ([#15](https://github.com/cahitatlas/metalreel/issues/15))
- [ ] Native SVG, `clip-path` and `mask` (today rendered once by WebKit and cached) ([#16](https://github.com/cahitatlas/metalreel/issues/16))

## Engine and performance

- [ ] **Incremental layout:** keep Yoga nodes between frames and re-measure only what changed. ([#17](https://github.com/cahitatlas/metalreel/issues/17))
- [ ] **Parallel rendering:** several JavaScriptCore contexts with frame ranges, merged in the encoder. *Estimate: 2–3× more throughput on long videos.* ([#18](https://github.com/cahitatlas/metalreel/issues/18))
- [ ] **Output formats:** ProRes, HDR (HLG / PQ), alpha channel, dual encoders on Max / Ultra chips. ([#19](https://github.com/cahitatlas/metalreel/issues/19))
- [ ] **Remotion CLI drop-in:** `npx metalreel render` with the same flags as `npx remotion render`, published to npm. ([#20](https://github.com/cahitatlas/metalreel/issues/20))
- [ ] **Prebuilt binaries:** a signed universal binary in GitHub Releases and a Homebrew formula, so Xcode is not required. ([#21](https://github.com/cahitatlas/metalreel/issues/21))

## Ideas

- [ ] **Neural Engine components:** on-device transcription for captions, face tracking for automatic reframing, background removal (Vision / Core ML), exposed as React components.
- [ ] **Native components (the React Native model):** heavy components written in Swift and used from TSX.
- [ ] **MetalReel Studio:** a SwiftUI app with a live Metal preview, timeline scrubbing and hot reload.
- [ ] **Render farm:** distribute frame ranges across several Macs.
