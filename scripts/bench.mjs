#!/usr/bin/env node
// Speed benchmark: Remotion (`npx remotion render`) vs MetalReel hybrid vs MetalReel native.
//
//   node scripts/bench.mjs --project examples TitleCard TalkingHead SlideCamera VerticalClip [--modes remotion,hybrid,native] [--out bench/results]
//
// Measured per run: wall time, frames/s, CPU time (user+sys from /usr/bin/time -l), peak memory, average and
// peak GPU utilization (sampled from IOAccelerator every 250 ms, no sudo needed), output size.
// Waits while macOS reports thermal throttling (pmset -g therm) so runs are comparable.
import {spawn, spawnSync, execFileSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const argv = process.argv.slice(2);
const opt = {}; const comps = [];
for (let i = 0; i < argv.length; i++) { if (argv[i].startsWith('--')) { opt[argv[i].slice(2)] = argv[i + 1]; i++; } else comps.push(argv[i]); }
const PROJECT = path.resolve(opt.project ?? path.join(ROOT, 'examples'));
const OUT = path.resolve(opt.out ?? path.join(ROOT, 'bench/results'));
const MODES = (opt.modes ?? 'remotion,hybrid,native').split(',');
const chrome = opt.chrome ?? process.env.METALREEL_CHROME;
fs.mkdirSync(path.join(OUT, 'videos'), {recursive: true});

const gpuNow = () => { try { const m = /"Device Utilization %"=(\d+)/.exec(execFileSync('ioreg', ['-r', '-d', '1', '-w', '0', '-c', 'IOAccelerator'], {encoding: 'utf8'})); return m ? +m[1] : null; } catch { return null; } };
const throttled = () => { const t = spawnSync('pmset', ['-g', 'therm'], {encoding: 'utf8'}).stdout; const m = /CPU_Speed_Limit\s*=\s*(\d+)/.exec(t); return m ? +m[1] < 100 : false; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const machine = (() => { try { return execFileSync('sysctl', ['-n', 'machdep.cpu.brand_string'], {encoding: 'utf8'}).trim(); } catch { return os.cpus()[0]?.model ?? '?'; } })();

function frameCount(comp) {
	const src = fs.readFileSync(path.join(PROJECT, 'src/Root.tsx'), 'utf8');
	const m = new RegExp(`id="${comp}"[^>]*durationInFrames=\\{(\\d+)\\}`).exec(src);
	return m ? +m[1] : null;
}

async function run(mode, comp) {
	while (throttled()) { process.stderr.write('  thermal throttling reported, waiting 30 s…\n'); await sleep(30000); }
	const out = path.join(OUT, 'videos', `${comp}-${mode}.mp4`);
	fs.rmSync(out, {force: true});
	const cmd = mode === 'remotion'
		? ['npx', 'remotion', 'render', comp, out, '--log=error', ...(chrome ? [`--browser-executable=${chrome}`] : [])]
		: [process.execPath, path.join(ROOT, 'js/cli/metalreel.mjs'), 'render', comp, '--project', PROJECT, '--mode', mode, '--out', out, ...(mode === 'hybrid' && chrome ? ['--chrome', chrome] : [])];
	const samples = []; const timer = setInterval(() => { const g = gpuNow(); if (g != null) samples.push(g); }, 250);
	const t0 = performance.now();
	const p = spawn('/usr/bin/time', ['-l', ...cmd], {cwd: mode === 'remotion' ? PROJECT : ROOT, stdio: ['ignore', 'pipe', 'pipe']});
	let err = '', so = '';
	p.stderr.on('data', (d) => (err += d)); p.stdout.on('data', (d) => (so += d));
	const code = await new Promise((r) => p.on('close', r));
	const wall = (performance.now() - t0) / 1000;
	clearInterval(timer);
	if (code !== 0) { process.stderr.write(err.slice(-3000)); throw new Error(`${mode} ${comp} failed`); }
	const user = +/([\d.]+) user/.exec(err)[1], sys = +/([\d.]+) sys/.exec(err)[1];
	const rss = +/(\d+)\s+maximum resident set size/.exec(err)[1];
	const frames = frameCount(comp);
	return {comp, mode, frames, wall: +wall.toFixed(2), fps: +(frames / wall).toFixed(1), cpu: +(user + sys).toFixed(1), cpuPct: Math.round(((user + sys) / wall) * 100),
		rssMB: Math.round(rss / 1e6), gpuAvg: samples.length ? Math.round(samples.reduce((a, b) => a + b, 0) / samples.length) : null, gpuPeak: samples.length ? Math.max(...samples) : null,
		sizeMB: +(fs.statSync(out).size / 1e6).toFixed(1), detail: (so.match(/DONE.*$/m) ?? [''])[0]};
}

// warm caches (bundles, Swift build, Chrome download) so timings measure rendering
for (const mode of MODES.filter((m) => m !== 'remotion')) spawnSync(process.execPath, [path.join(ROOT, 'js/cli/metalreel.mjs'), 'still', comps[0], '--project', PROJECT, '--mode', mode, '--frame', '0', '--png', path.join(os.tmpdir(), 'metalreel-warm.png'), ...(mode === 'hybrid' && chrome ? ['--chrome', chrome] : [])], {stdio: 'ignore'});

const results = [];
for (const comp of comps) for (const mode of MODES) {
	process.stderr.write(`${comp} · ${mode}…\n`);
	const r = await run(mode, comp); results.push(r);
	process.stderr.write(`  ${r.wall} s, ${r.fps} fps, CPU ${r.cpu} s (${r.cpuPct}%), GPU avg ${r.gpuAvg}% peak ${r.gpuPeak}%\n`);
	fs.writeFileSync(path.join(OUT, 'results.json'), JSON.stringify({machine, date: new Date().toISOString(), results}, null, 2));
}
const rows = results.map((r) => {
	const base = results.find((x) => x.comp === r.comp && x.mode === 'remotion');
	return `| ${r.comp} | ${r.mode} | ${r.frames} | ${r.wall} | ${r.fps} | ${base ? (base.wall / r.wall).toFixed(1) + '×' : '–'} | ${r.cpu} | ${r.gpuAvg ?? '–'}% | ${r.rssMB} | ${r.sizeMB} |`;
});
const md = [`Machine: ${machine}, macOS ${os.release()}. Measured ${new Date().toISOString().slice(0, 10)}.`, '',
	'| Composition | Mode | Frames | Wall (s) | FPS | Speed-up | CPU time (s) | GPU avg | Peak RSS (MB) | File (MB) |', '|---|---|---|---|---|---|---|---|---|---|', ...rows].join('\n');
fs.writeFileSync(path.join(OUT, 'results.md'), md + '\n');
console.log(md);
