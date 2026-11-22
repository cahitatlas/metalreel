# Contributing

Thanks for helping! The most useful contributions right now:

1. **A composition that renders differently than Remotion.** Run
   `node scripts/compare.mjs --project <your project> YourComp:frame` and open an issue with the side-by-side
   and diff images it writes (please only attach media you are allowed to share).
2. **CSS / element coverage.** Native painting lives in `Sources/metalreel/Layout.swift` (layout → display list)
   and `Painter.swift` (display list → Metal). Anything not native yet should still render through the WebKit
   fallback; turning a fallback into a native path is a great first PR.
3. **Benchmarks on other Macs.** `node scripts/bench.mjs --project examples TitleCard TalkingHead` and share
   `bench/results/results.md`.

Development loop:

```bash
cd js && npm install && node build.mjs && cd ..
swift build -c release
node js/cli/metalreel.mjs still TitleCard --project examples --frame 60 --png /tmp/frame.png
```

Set `METALREEL_JS_LOG=1` to see `console.log` from compositions, and pass `--dump-ops ops.ndjson` to inspect
the display list.

Code style: tabs, English identifiers and comments, keep files focused. Please don't commit media.
