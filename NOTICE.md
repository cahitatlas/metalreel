# Third-party notices

MetalReel's own code is MIT licensed (see `LICENSE`). It includes or builds with:

| Component | Where | License |
|---|---|---|
| [Yoga](https://github.com/facebook/yoga) (Meta) | vendored in `Sources/CYoga` (commit in `Sources/CYoga/YOGA_COMMIT.txt`) | MIT, `Sources/CYoga/LICENSE` |
| [react-reconciler](https://github.com/facebook/react) and `scheduler` (Meta) | bundled into `js/dist/react-dom.cjs` at build time (npm dependency, not committed) | MIT |
| [esbuild](https://esbuild.github.io/) | build tool for `js/dist` | MIT |
| [puppeteer-core](https://pptr.dev/) | hybrid mode only (optional npm dependency) | Apache-2.0 |

## Remotion

MetalReel is an independent project. It is **not affiliated with, endorsed by, or sponsored by Remotion**.
It does not contain Remotion source code. It runs the JavaScript bundle that **your** project builds with
Remotion's own bundler, so your use of Remotion stays governed by the
[Remotion License](https://github.com/remotion-dev/remotion/blob/main/LICENSE.md): companies above the
free-tier threshold need a Remotion company license, whether frames are rendered by Chrome or by MetalReel.

"Remotion" is used here only to describe compatibility.
