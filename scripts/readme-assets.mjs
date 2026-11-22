#!/usr/bin/env node
// Regenerates every README visual and table from measured data:
//   docs/img/speed.svg, cpu.svg      ← bench/results/results.json   (scripts/charts.mjs)
//   docs/img/hero.jpg                ← bench/compare/TitleCard-60-sbs.png
//   docs/img/compare/*.jpg           ← side-by-side + difference heat maps from bench/compare
//   docs/img/gallery.jpg             ← native frames of every sample composition
//   docs/img/demo.gif                ← bench/results/videos/TitleCard-native.mp4 (ffmpeg from @remotion/compositor)
// and replaces the RESULTS / BENCH / COMPARE blocks in README.md.
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const IMG = path.join(ROOT, 'docs/img'); fs.mkdirSync(path.join(IMG, 'compare'), {recursive: true});
const CMP = path.join(ROOT, 'bench/compare');
const run = (cmd, args, extra = {}) => { const r = spawnSync(cmd, args, {encoding: 'utf8', ...extra}); if (r.status !== 0) throw new Error(`${cmd} failed: ${r.stderr}`); return r.stdout; };
const jpg = (src, dst, width) => run('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '82', ...(width ? ['--resampleWidth', String(width)] : []), src, '--out', dst]);
const tool = (t) => { const bin = path.join(ROOT, '.build/tools', t), src = path.join(ROOT, 'tools', t + '.swift'); if (!fs.existsSync(bin) || fs.statSync(src).mtimeMs > fs.statSync(bin).mtimeMs) run('swiftc', ['-O', src, '-o', bin]); return bin; };

run(process.execPath, [path.join(ROOT, 'scripts/charts.mjs')]);
const {results} = JSON.parse(fs.readFileSync(path.join(ROOT, 'bench/results/results.json'), 'utf8'));
const cmp = JSON.parse(fs.readFileSync(path.join(CMP, 'results.json'), 'utf8'));

// hero: TitleCard side by side
jpg(path.join(CMP, 'TitleCard-60-sbs.png'), path.join(IMG, 'hero.jpg'), 1600);

// compare gallery (pairs + heat maps)
const picks = cmp.map((r) => `${r.comp}-${r.frame}`);
let section = '| Composition (frame) | MetalReel native vs Remotion | Difference | MAE native | MAE hybrid |\n|---|---|---|---|---|\n';
for (const k of picks) {
	const r = cmp.find((x) => `${x.comp}-${x.frame}` === k);
	jpg(path.join(CMP, `${k}-sbs.png`), path.join(IMG, 'compare', `${k}.jpg`), 900);
	jpg(path.join(CMP, `${k}-diff-native.png`), path.join(IMG, 'compare', `${k}-diff.jpg`), 320);
	section += `| ${r.comp} (${r.frame}) | <img src="docs/img/compare/${k}.jpg" width="420"> | <img src="docs/img/compare/${k}-diff.jpg" width="160"> | ${r.native.toFixed(2)} | ${r.hybrid != null ? r.hybrid.toFixed(2) : '–'} |\n`;
}
section += '\nMAE is the mean absolute difference per RGB channel (0–255). Both columns are measured against `npx remotion still`.\nFor scale: re-encoding the Remotion TitleCard frame as JPEG at quality 90 and comparing it with the original gives MAE 0.94 (measured with the same tool). The largest visible difference is the gradient on the Audiogram cover art; hybrid mode on FeatureCheck differs more than native (MAE 5.51 versus 0.72).\n';

// use-case gallery from native frames
const order = ['TitleCard-60', 'TalkingHead-200', 'SlideCamera-200', 'VerticalClip-240', 'DataChart-120', 'YearInReview-100', 'Audiogram-60', 'CodeWalkthrough-200', 'ProductPromo-125', 'PhotoSlideshow-110', 'LongForm-4000', 'FeatureCheck-90'];
const labels = {TitleCard: 'Animated title + video', TalkingHead: 'Captioned talking head', SlideCamera: 'Slides + camera bubble', VerticalClip: 'Vertical social cut', DataChart: 'Data chart', YearInReview: 'Personalized year in review', Audiogram: 'Podcast audiogram', CodeWalkthrough: 'Code walkthrough', ProductPromo: 'Promo with transitions', PhotoSlideshow: 'Photo slideshow', LongForm: 'Long-form lecture (5 min)', FeatureCheck: 'Feature check: grid, RTL, justify…'};
const sheet = path.join(ROOT, '.build/gallery.png');
run(tool('contact-sheet'), [sheet, '4', '420', ...order.filter((k) => fs.existsSync(path.join(CMP, `${k}-native.png`))).flatMap((k) => [path.join(CMP, `${k}-native.png`), labels[k.split('-')[0]]])]);
jpg(sheet, path.join(IMG, 'gallery.jpg'));

// demo gif (ffmpeg shipped with @remotion/compositor; any ffmpeg works)
const ffdir = path.join(ROOT, 'examples/node_modules/@remotion/compositor-darwin-arm64');
const ff = fs.existsSync(path.join(ffdir, 'ffmpeg')) ? path.join(ffdir, 'ffmpeg') : 'ffmpeg';
const demoSrc = path.join(ROOT, 'bench/results/videos/TitleCard-native.mp4');
if (fs.existsSync(demoSrc)) run(ff, ['-y', '-v', 'error', '-i', demoSrc, '-r', '12', '-t', '5', '-vf', 'scale=540:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=bayer:bayer_scale=4', path.join(IMG, 'demo.gif')], {env: {...process.env, DYLD_LIBRARY_PATH: ffdir}});

// README blocks
const nat = results.filter((r) => r.mode === 'native');
const ratio = (r, f) => { const b = results.find((x) => x.comp === r.comp && x.mode === 'remotion'); return b ? f(b, r) : null; };
const speed = nat.map((r) => ratio(r, (b, x) => b.wall / x.wall)).filter(Boolean);
const cpu = nat.map((r) => ratio(r, (b, x) => b.cpu / x.cpu)).filter(Boolean);
const maes = cmp.map((r) => r.native);
const rng = (a, d = 1, s = '×') => `${Math.min(...a).toFixed(d)}–${Math.max(...a).toFixed(d)}${s}`;
let readme = fs.readFileSync(path.join(ROOT, 'README.md'), 'utf8');
const swap = (tag, body) => { readme = readme.replace(new RegExp(`<!-- ${tag}:START -->[\\s\\S]*?<!-- ${tag}:END -->`), `<!-- ${tag}:START -->\n${body}\n<!-- ${tag}:END -->`); };
const long = results.filter((r) => r.comp === 'LongForm');
const longLine = long.length === 3 ? ` On the 5-minute composition (9,000 frames): Remotion ${long[0].wall.toFixed(0)} s, hybrid ${long[1].wall.toFixed(0)} s, native ${long[2].wall.toFixed(0)} s.` : '';
swap('RESULTS', `**Measured on an Apple M5 Max (macOS 27), ${nat.length} sample compositions in [\`examples/\`](examples):** native mode rendered **${rng(speed)} faster** than \`npx remotion render\` and used **${rng(cpu, 0)} less CPU time**.${longLine} Mean pixel difference to Remotion's own output: **MAE ${rng(maes, 2, '')}** on a 0–255 scale. Details in [Benchmarks](#benchmarks).`);
swap('BENCH', fs.readFileSync(path.join(ROOT, 'bench/results/results.md'), 'utf8').trim());
swap('COMPARE', section.trim());
readme = readme.replace('docs/img/hero.png', 'docs/img/hero.jpg').replace('docs/img/gallery.png', 'docs/img/gallery.jpg');
fs.writeFileSync(path.join(ROOT, 'README.md'), readme);
console.log('README assets updated');
