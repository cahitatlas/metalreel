# Media attribution

No third-party media is committed to this repository. `scripts/download-media.sh` downloads the clips below
into `examples/public/media/` (git-ignored) and derives three still "photos" from them for the slideshow sample.

| File | Title / source | Creator | License |
|---|---|---|---|
| `talking-head.mp4` | [Portrait of an influencer talking to the camera](https://mixkit.co/free-stock-video/portrait-of-an-influencer-talking-to-the-camera-42323/) | Mixkit | [Mixkit Stock Video Free License](https://mixkit.co/license/) |
| `meadow.mp4` | [Countryside meadow](https://mixkit.co/free-stock-video/countryside-meadow-4075/) | Mixkit | [Mixkit Stock Video Free License](https://mixkit.co/license/) |
| `vertical.mp4` | [Winter fashion cold looking woman concept](https://mixkit.co/free-stock-video/winter-fashion-cold-looking-woman-concept-video-39874/) | Mixkit | [Mixkit Stock Video Free License](https://mixkit.co/license/) |
| `ambient.wav` | [Ambient Seattle 2024 (WayVSumtInThWay)](https://commons.wikimedia.org/wiki/File:Paul_Kuniholm_Ambient_Seattle_2024_(WayVSumtInThWay).wav) | Paul Kuniholm (1stArtHistorian) | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| `img/photo-*.jpg` | stills extracted locally from the clips above | — | same as the source clip |

Mixkit clips are free to use in projects; they may not be redistributed as stand-alone files, which is why
they are downloaded on demand instead of committed. Check the license page before commercial use.

Images in `docs/img/` are frames rendered by MetalReel and by Remotion from the sample compositions in
`examples/`, which use the clips above. Fonts in the samples (Inter, Playfair Display) are loaded at render time
from Google Fonts via `@remotion/google-fonts` (SIL Open Font License 1.1).

Optional larger test footage, not used by default: Blender open movies such as
[Big Buck Bunny](https://peach.blender.org/) and [Tears of Steel](https://mango.blender.org/)
((c) Blender Foundation, CC BY 3.0).
