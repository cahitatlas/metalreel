# Roadmap

MetalReel's goal is to render every Remotion composition natively on Apple Silicon, without a browser.
This file is the public to-do list. Each item has a matching GitHub issue with the `roadmap` label;
comment there if you need it, or pick it up (see [CONTRIBUTING.md](CONTRIBUTING.md)).

Estimates are rough guesses, not measurements.

## Why some things still need Chrome

Metal is only the paint engine. Native mode runs your JavaScript in JavaScriptCore, which has no browser APIs.
Everything a composition calls (DOM, CSS, text, video, fetch) has to be re-implemented on Apple's frameworks.
The common parts are done. The items below are not yet, so those compositions fall back to
[hybrid mode](README.md#two-modes) (Chrome produces the layout, Metal still paints and encodes).

## Native gaps

Ordered by how many real-world projects they unblock.

### Next

- [ ] **Web Audio for audio visualizations** (`useAudioData`, `visualizeAudio`, `getWaveformPortion`). Decode audio with AVFoundation and expose `AudioContext.decodeAudioData` through the bridge. Unblocks audiograms and music visualizers. *Estimate: 1–2 days.*
- [ ] **Measurement APIs** (`getBoundingClientRect`, `offsetWidth`/`offsetHeight`, `scrollWidth`, `@remotion/layout-utils` `measureText` / `fitText`). Feed Yoga and Core Text results back into the DOM shim. Unblocks auto-fitting titles and Code Hike–style animations. *Estimate: 2–3 days.*
- [ ] **Canvas 2D** (`<canvas>` with `CanvasRenderingContext2D` on Core Graphics / Metal). Unblocks canvas charts, particle effects and most of the work for the new `<Video>` component. *Estimate: about 1 week.*
- [ ] **`@remotion/media` `<Video>` / `<Audio>`** (the newer canvas and WebCodecs–based components). Map them to the existing VideoToolbox decoder. *Depends on canvas 2D.*
- [ ] **Stylesheets and `className`** (CSS files, CSS modules, Tailwind). A selector matcher and cascade in front of the existing inline-style path. *Estimate: about 1 week.*

### Later

- [ ] **3D models without WebGL:** a native `<Model src="model.glb">`-style component rendered with SceneKit / RealityKit on Metal, covering product spins and turntables. *Estimate: about 1 week.*
- [ ] **WebGL / three.js / `@remotion/three`:** a WebGL implementation on Metal (ANGLE-style). *Hard; several weeks.*
- [ ] **Lottie** (`@remotion/lottie`): draw Lottie JSON natively instead of through the SVG renderer. *Estimate: about 1 week.*
- [ ] **`@remotion/skia`:** CanvasKit needs WebGL or a Skia build for Metal. *Hard.*
- [ ] **Maps** (Mapbox GL and similar): needs WebGL. *Follows the WebGL item.*

### Small CSS gaps

Each is a few hours to a day.

- [ ] `text-decoration` (underline, line-through, overline, decoration color and thickness)
- [ ] `-webkit-text-stroke` (outlined text)
- [ ] Per-corner `border-radius` (today one radius is used for all corners)
- [ ] Real 3D transforms: `perspective`, `rotateX` / `rotateY`, `transform-style: preserve-3d` (today approximated as 2D)
- [ ] `display: inline-block` flow
- [ ] The rest of CSS grid: explicit placement, spans, `auto-fill` / `auto-fit`, named areas
- [ ] Native SVG, `clip-path` and `mask` (today rendered once by WebKit and cached)

## Engine and performance

- [ ] **Incremental layout:** keep Yoga nodes between frames and re-measure only what changed.
- [ ] **Parallel rendering:** several JavaScriptCore contexts with frame ranges, merged in the encoder. *Estimate: 2–3× more throughput on long videos.*
- [ ] **Output formats:** ProRes, HDR (HLG / PQ), alpha channel, dual encoders on Max / Ultra chips.
- [ ] **Remotion CLI drop-in:** `npx metalreel render` with the same flags as `npx remotion render`, published to npm.
- [ ] **Prebuilt binaries:** a signed universal binary in GitHub Releases and a Homebrew formula, so Xcode is not required.

## Ideas

- [ ] **Neural Engine components:** on-device transcription for captions, face tracking for automatic reframing, background removal (Vision / Core ML), exposed as React components.
- [ ] **Native components (the React Native model):** heavy components written in Swift and used from TSX.
- [ ] **MetalReel Studio:** a SwiftUI app with a live Metal preview, timeline scrubbing and hot reload.
- [ ] **Render farm:** distribute frame ranges across several Macs.
