# Architecture

MetalReel renders a Remotion project without Chrome. It keeps Remotion's JavaScript exactly as it is and swaps
the parts underneath: the browser engine becomes JavaScriptCore + Yoga + Core Text + Core Image/Metal +
VideoToolbox.

```
 your Remotion project ──(Remotion's own bundler, react-dom aliased)──▶ bundle/
                                                                         │
 Swift process ┌─────────────────────────────────────────────────────────▼─────────────┐
               │ JavaScriptCore                                                       │
               │   prelude.js  (event loop, DOM nodes, fetch, FontFace, URL, Blob…)    │
               │   bundle.js   (remotion + @remotion/* + your components, unchanged)   │
               │   react-dom → MetalReel host renderer (react-reconciler)              │
               │        │ per frame: remotion_setFrame(f) → settle → __mr_snapshot()   │
               └────────┼─────────────────────────────────────────────────────────────┘
                        ▼ element tree (JSON, a few KB)
               Layout.swift   CSS cascade → Yoga nodes → layout (1/64 px grid)
               Text.swift     paragraphs → Core Text lines (Chrome-like breaking)
                        ▼ display list (boxes, gradients, shadows, text lines, images, video frames)
               Painter.swift  Core Image graph on Metal; videos via AVAssetReader (hardware decode)
                        ▼ IOSurface-backed CVPixelBuffer (zero copy)
               Encoder.swift  VideoToolbox H.264/HEVC + AVFoundation audio mix + passthrough mux
```

## Source map

| File | Role |
|---|---|
| `js/runtime/prelude.js` | Browser shims for JavaScriptCore: event loop, DOM, `fetch`, `URL`, `Blob`, `FontFace`, `document.fonts`, tree snapshot. |
| `js/runtime/react-dom.js` | Replacement for `react-dom` and `react-dom/client`, built on `react-reconciler`. Host nodes are the prelude's DOM nodes. |
| `js/cli/metalreel.mjs` | Single command. Bundles with `@remotion/bundler` (cached), builds Swift if needed, and runs native or hybrid. |
| `js/hybrid/extract.mjs` | Hybrid front end. Headless Chrome produces a display list through CDP `DOMSnapshot`, with no screenshots. |
| `Sources/metalreel/JSRuntime.swift` | JSContext, the native bridge (`__mr`), the event-loop driver, bundle loading, and Chrome-free `selectComposition`. |
| `Sources/metalreel/CSS.swift` | Parses specified CSS values (colors, lengths, `calc()`, transforms, shadows, gradients, filters). |
| `Sources/metalreel/Layout.swift` | Box tree, inheritance, UA defaults, Yoga, stacking order, and display-list emission. |
| `Sources/metalreel/Text.swift` | Inline formatting: white-space, break opportunities, line boxes and run metrics. |
| `Sources/metalreel/WebFallback.swift` | Renders unsupported elements with WebKit and caches the result. |
| `Sources/metalreel/Painter.swift` | Paints the display list (shared by both modes). |
| `Sources/metalreel/Encoder.swift` | Video encoding, the audio clip list (Remotion's `calculateAssetPositions`) and muxing. |
| `Sources/CYoga` | Vendored Yoga (MIT). |

## Phases

| Phase | Content | Status |
|---|---|---|
| 0 | Inventory of real projects: CSS properties, elements, packages | done (summary below) |
| 1 | JavaScriptCore core and browser shims: timers, `fetch`/`staticFile`, `delayRender`, `FontFace` | done |
| 2 | React host renderer (react-reconciler) | done |
| 3 | Yoga layout + Core Text paragraphs | working; gaps listed in the roadmap |
| 4 | Metal painting (shared with hybrid) | working |
| 5 | Pixel validation against Remotion (`scripts/compare.mjs`) | done, MAE per frame in `bench/compare` |
| 6 | SwiftUI Studio with live Metal preview | not started |

### Phase 0 — what real projects use

We counted one production Remotion project (36 source files, 531 inline style objects, 520 JSX elements):

- **Elements:** 69% `div`/`span`, 28% SVG (mostly simple shapes), about 1% `three.js`. Media goes through `<Img>` (43 uses) and `<OffthreadVideo>` (9).
- **Top CSS properties:** position, opacity, left, color, top, width, fontFamily, fontSize, fontWeight, background, height, lineHeight, display, transform, alignItems, borderRadius, letterSpacing, textAlign, gap, padding.
- **Effects:** radial and linear gradients (59), text-shadow (19), filters (12; blur, drop-shadow, brightness), mix-blend-mode (7), a few masks and clip-paths.
- **APIs:** interpolate (174), useCurrentFrame (114), Sequence (70), staticFile (56), Easing (~60), Google Fonts `loadFont` (23).

This set the order of work: absolute and flex layout, text, gradients, opacity and transforms first. SVG and WebGL go to the fallback.

## How a frame is produced (native mode)

1. **Boot (once, ~0.1 s).** JSRuntime evaluates `prelude.js`, then runs the scripts of the bundle's `index.html` in order. Webpack chunks load through `<script>` elements that the prelude evaluates. `remotion_setBundleMode({type: 'evaluation'})` plus `remotion_calculateComposition(id)` replaces Remotion's Chrome-based `selectComposition()`, so `calculateMetadata` runs too.
2. **Mount.** `remotion_setBundleMode({type: 'composition', …})` renders Remotion's own render entry (`CompositionManager`, `RemotionRoot`, the portal) through our reconciler.
3. **Per frame.** `remotion_setFrame(f)` is followed by a settle step: Swift runs the JS event loop one task at a time, so microtasks drain between tasks as in a browser, until `remotion_renderReady === true` with no immediate work left. Because the loop is deterministic, React always commits before Remotion's `requestAnimationFrame` releases the frame. This removes the "stale frame" race the Chrome path has to guard against.
4. **Media.** `<OffthreadVideo>` fetches `/proxy?src=…&time=…`. The prelude answers with a marker blob, so no pixels ever enter JavaScript. The `<img>` it renders carries `{video, time}` into the display list, and the Painter decodes that exact frame with AVAssetReader (hardware decode, IOSurface).
5. **Snapshot.** The tree is serialized only when it changed: tag, inline style, a few attributes, and text.
6. **Layout.** CSS inheritance and UA defaults run, then Yoga builds its tree. Blocks become flex columns, `position: static` is honored, sizing is border-box (as Remotion injects), and the grid is 1/64 px to match Chrome's LayoutUnit. Text containers are Yoga leaves whose measure function runs the paragraph layout.
7. **Paint list.** Stacking order follows negative z-index, then in-flow boxes, then positioned boxes, then positive z-index. Transforms accumulate into one affine per element. Axis-aligned boxes are emitted in composition pixels; rotated or skewed ones carry their matrix and local size. Overflow clips are emitted at the padding box, with the matrix when rotated.
8. **Paint + encode.** This step is the same as hybrid mode, described below.

## Hybrid mode

Hybrid mode keeps Chrome for DOM, style and layout, but never takes screenshots. Each Chrome tab returns a
roughly 2 KB display list per frame (CDP `DOMSnapshot` with computed styles, paint order and text boxes), and
Swift paints and encodes it. Chrome never decodes video: the OffthreadVideo proxy is answered with a 1×1 PNG,
and the frame time travels in the display list. Use hybrid mode for compositions that need canvas or WebGL.

## WebKit fallback

When an element can't be painted natively (SVG, `clip-path`, `mask`, `drop-shadow` and other non-color
filters, raw HTML, `.svg` images), WebKit renders **that element only**. It does this offscreen, in the
element's local coordinate space, supersampled when the element is scaled up. The result is cached as a
PNG keyed by content. The Painter applies the element's transform, opacity and clips, so an animated
transform never triggers a re-render. In the VerticalClip sample, a pulsing SVG icon took 12 WebKit renders
for 300 frames.

## Lessons carried over from the prototype

- **AVAssetReader stops after about 682 s of continuous reading** ("Cannot Decode"). `VideoSource` detects that the reader ended early and reopens it at the current time.
- **Frame selection.** Remotion shows the last frame whose timestamp is ≤ t. With 23.976 fps sources inside 30 fps compositions, a quarter-frame tolerance picked the next frame (MAE 10 → 2.7 after the fix). The tolerance is now 1.5 ms.
- **HLG sources.** Remotion tone-maps HLG with ffmpeg's `zscale → hable → BT.709`. A 64³ LUT reproduces that chain, because Apple's own tone mapping came out about 10 levels darker.
- **Text baseline.** Line boxes use Blink's rounded ascent and descent, and half-leading is split as LayoutNG does (floor to 1/64 above the baseline). `chromeAscent` picks the hhea, typo or win metrics that match the box.
- **Gradient stops.** Gradient stops can be px, % or deg. A transparent stop takes its neighbor's color, the equivalent of premultiplied interpolation.
- **Background vs border.** Backgrounds cover the border box, and the border ring is painted on top. This matters with translucent colors.
