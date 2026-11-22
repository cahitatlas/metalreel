#!/usr/bin/env node
// metalreel — one command for all three render paths of a Remotion project.
//
//   node js/cli/metalreel.mjs render <CompositionId> --project <remotion project dir> [--mode native|hybrid]
//        [--frames a-b] [--out file.mp4] [--codec h264|hevc] [--bitrate 6M] [--props '{"x":1}'] [--tabs 8]
//   node js/cli/metalreel.mjs still <CompositionId> --project <dir> --frame 30 --png out.png [--mode native|hybrid]
//   node js/cli/metalreel.mjs compositions --project <dir>
//
// native (default): Remotion's own bundler builds the project with ONE change — `react-dom` is aliased to
//   MetalReel's host renderer — then the Swift binary runs it in JavaScriptCore. No browser is started.
// hybrid: the unmodified bundle runs in headless Chrome, which only produces a display list (no screenshots);
//   Swift paints and encodes. Use it for compositions native mode can't handle yet (canvas/WebGL).
import {spawn, spawnSync} from 'node:child_process';
import {createRequire} from 'node:module';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const argv = process.argv.slice(2);
const cmd = argv[0];
const positional = argv.slice(1).filter((a, i, arr) => !a.startsWith('--') && !(arr[i - 1] ?? '').startsWith('--'));
const opt = {};
for (let i = 1; i < argv.length; i++) if (argv[i].startsWith('--')) { const k = argv[i].slice(2); const v = argv[i + 1]; if (v === undefined || v.startsWith('--')) opt[k] = true; else { opt[k] = v; i++; } }
const die = (m) => { console.error('metalreel: ' + m); process.exit(1); };
if (!['render', 'still', 'compositions'].includes(cmd)) die('usage: metalreel render|still|compositions <CompositionId> --project <dir> [--mode native|hybrid]');
const PROJECT = path.resolve(opt.project ?? process.cwd());
if (!fs.existsSync(path.join(PROJECT, 'package.json'))) die(`no package.json in ${PROJECT}`);
const MODE = opt.mode ?? 'native';
const require = createRequire(path.join(PROJECT, 'package.json'));
const t0 = Date.now();
const elapsed = () => ((Date.now() - t0) / 1000).toFixed(2) + ' s';

// ── 1) Bundle with Remotion's bundler (cached by source hash + mode) ─────────
function entryPoint() {
	for (const c of ['src/index.ts', 'src/index.tsx', 'src/index.js', 'src/index.jsx', 'remotion/index.ts', 'app/remotion/index.ts']) if (fs.existsSync(path.join(PROJECT, c))) return path.join(PROJECT, c);
	die('could not find the Remotion entry point (src/index.ts); pass --entry');
}
const ENTRY = opt.entry ? path.resolve(opt.entry) : entryPoint();
const hash = crypto.createHash('sha1');
const scan = (d) => { for (const e of fs.readdirSync(d, {withFileTypes: true}).sort((a, b) => a.name.localeCompare(b.name))) {
	if (['node_modules', 'out', 'public', '.git', 'build', 'dist'].includes(e.name) || e.name.startsWith('.')) continue;
	const p = path.join(d, e.name);
	if (e.isDirectory()) scan(p); else { const s = fs.statSync(p); hash.update(`${p}|${s.size}|${s.mtimeMs}\n`); }
} };
scan(PROJECT);
const SHIM = path.join(ROOT, 'js/dist/react-dom.cjs');
if (MODE === 'native' && !fs.existsSync(SHIM)) {
	const r = spawnSync(process.execPath, [path.join(ROOT, 'js/build.mjs')], {stdio: 'inherit'}); if (r.status !== 0) die('js build failed');
}
hash.update(MODE + (MODE === 'native' ? fs.statSync(SHIM).mtimeMs : ''));
const CACHE = path.join(PROJECT, 'node_modules/.cache/metalreel');
const BUNDLE = path.join(CACHE, `bundle-${MODE}-${hash.digest('hex').slice(0, 12)}`);
if (!fs.existsSync(path.join(BUNDLE, 'index.html'))) {
	process.stderr.write(`bundling ${path.relative(process.cwd(), ENTRY)} (${MODE})…\n`);
	for (const d of fs.existsSync(CACHE) ? fs.readdirSync(CACHE) : []) if (d.startsWith(`bundle-${MODE}-`)) fs.rmSync(path.join(CACHE, d), {recursive: true, force: true});
	fs.mkdirSync(CACHE, {recursive: true});
	const {bundle} = require('@remotion/bundler');
	const webpackOverride = MODE !== 'native' ? (c) => c : (c) => ({
		...c, resolve: {...c.resolve, alias: {...(c.resolve?.alias ?? {}), 'react-dom/client$': SHIM, 'react-dom$': SHIM}},
	});
	await bundle({entryPoint: ENTRY, rootDir: PROJECT, outDir: BUNDLE, publicDir: path.join(PROJECT, 'public'), symlinkPublicDir: true, enableCaching: true, onProgress: () => {}, webpackOverride});
	process.stderr.write(`bundled in ${elapsed()}\n`);
}

// ── 2) Swift binary ──────────────────────────────────────────────────────────
const BIN = path.join(ROOT, '.build/release/metalreel');
const swiftSources = fs.readdirSync(path.join(ROOT, 'Sources/metalreel'), {recursive: true}).map((f) => path.join(ROOT, 'Sources/metalreel', f)).filter((f) => fs.statSync(f).isFile());
if (!fs.existsSync(BIN) || Math.max(...swiftSources.map((f) => fs.statSync(f).mtimeMs)) > fs.statSync(BIN).mtimeMs) {
	process.stderr.write('building the Swift renderer (swift build -c release)…\n');
	const r = spawnSync('swift', ['build', '-c', 'release', '--product', 'metalreel'], {cwd: ROOT, stdio: ['ignore', 'ignore', 'inherit']});
	if (r.status !== 0) die('swift build failed');
}

const passthrough = (keys) => keys.flatMap((k) => (opt[k] !== undefined && opt[k] !== true ? ['--' + k, String(opt[k])] : opt[k] === true ? ['--' + k] : []));
const run = (bin, a, extra = {}) => new Promise((res) => { const p = spawn(bin, a, {stdio: ['ignore', 'inherit', 'inherit'], ...extra}); p.on('close', res); });

// ── 3) native ────────────────────────────────────────────────────────────────
if (MODE === 'native') {
	if (cmd === 'compositions') process.exit(await run(BIN, ['compositions', '--bundle', BUNDLE]));
	const comp = positional[0] ?? die('missing composition id');
	const out = path.resolve(opt.out ?? path.join(PROJECT, 'out', `${comp}-native.mp4`));
	const a = ['render', '--bundle', BUNDLE, '--comp', comp, ...passthrough(['frames', 'codec', 'bitrate', 'props', 'dump-ops', 'no-webkit', 'muted'])];
	if (cmd === 'still') a.push('--still', String(opt.frame ?? 0), '--png', path.resolve(opt.png ?? `${comp}.png`)); else a.push('--out', out);
	const code = await run(BIN, a);
	process.stderr.write(`total ${elapsed()} (bundle cache + render)\n`);
	process.exit(code);
}

// ── 4) hybrid ────────────────────────────────────────────────────────────────
if (MODE === 'hybrid') {
	const {selectComposition, getCompositions, ensureBrowser} = require('@remotion/renderer');
	const {NoReactInternals} = require('remotion/no-react');
	let chrome = opt.chrome ?? process.env.METALREEL_CHROME;
	if (!chrome) { const s = await ensureBrowser({logLevel: 'error'}); chrome = s?.path ?? s?.executablePath; }
	const browserExecutable = chrome && fs.existsSync(chrome) ? chrome : null;
	if (cmd === 'compositions') { for (const c of await getCompositions(BUNDLE, {browserExecutable, logLevel: 'error'})) console.log(c.id); process.exit(0); }
	const id = positional[0] ?? die('missing composition id');
	const inputProps = opt.props ? JSON.parse(opt.props) : {};
	const comp = await selectComposition({serveUrl: BUNDLE, id, inputProps, browserExecutable, logLevel: 'error'});
	const props = NoReactInternals.serializeJSONWithSpecialTypes({data: comp.props, indent: undefined, staticBase: null}).serializedString;
	let [a, b] = [0, comp.durationInFrames - 1];
	if (cmd === 'still') { a = b = +(opt.frame ?? 0); }
	else if (opt.frames) { const p = String(opt.frames).split('-').map(Number); a = p[0]; b = Number.isFinite(p[1]) ? p[1] : p[0]; }
	b = Math.min(b, comp.durationInFrames - 1);
	const tabs = String(opt.tabs ?? Math.max(4, Math.min(12, os.cpus().length - 4)));
	const exe = chrome ?? die('could not locate Chrome; pass --chrome');
	const ex = spawn(process.execPath, [path.join(ROOT, 'js/hybrid/extract.mjs'), '--bundle', BUNDLE, '--comp', id, '--start', String(a), '--count', String(b - a + 1), '--tabs', cmd === 'still' ? '1' : tabs,
		'--w', String(comp.width), '--h', String(comp.height), '--fps', String(comp.fps), '--dur', String(comp.durationInFrames), '--props', props, '--chrome', exe], {stdio: ['ignore', 'pipe', 'inherit']});
	const drawArgs = cmd === 'still' ? ['draw', '--png-frame', String(a), '--png', path.resolve(opt.png ?? `${id}.png`)] : ['draw', '--out', path.resolve(opt.out ?? path.join(PROJECT, 'out', `${id}-hybrid.mp4`)), ...passthrough(['codec', 'bitrate'])];
	const dr = spawn(BIN, drawArgs, {stdio: ['pipe', 'inherit', 'inherit']});
	ex.stdout.pipe(dr.stdin);
	dr.stdin.on('error', () => {});
	const [ce, cd] = await Promise.all([new Promise((r) => ex.on('close', r)), new Promise((r) => dr.on('close', r))]);
	process.stderr.write(`total ${elapsed()}\n`);
	process.exit(cd !== 0 ? cd : (cmd === 'still' ? 0 : ce));
}
die(`unknown --mode ${MODE} (native | hybrid)`);
