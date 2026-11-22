#!/usr/bin/env node
// Pixel comparison against Remotion's own renderer.
//
//   node scripts/compare.mjs --project examples --frames TitleCard:30,90 TalkingHead:120 [--hybrid] [--out bench/compare]
//
// For every composition/frame: renders a still with `npx remotion still` (Chrome), with MetalReel native mode
// (and hybrid mode with --hybrid), then writes side-by-side images, a difference heat map and the mean absolute
// error (0–255, RGB) to <out>/results.json and <out>/results.md.
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const argv = process.argv.slice(2);
const opt = {}; const items = [];
for (let i = 0; i < argv.length; i++) { if (argv[i].startsWith('--')) { const v = argv[i + 1]; if (v && !v.startsWith('--') && !v.includes(':')) { opt[argv[i].slice(2)] = v; i++; } else opt[argv[i].slice(2)] = true; } else items.push(argv[i]); }
const PROJECT = path.resolve(opt.project ?? path.join(ROOT, 'examples'));
const OUT = path.resolve(opt.out ?? path.join(ROOT, 'bench/compare'));
fs.mkdirSync(OUT, {recursive: true});
const TOOLS = path.join(ROOT, '.build/tools'); fs.mkdirSync(TOOLS, {recursive: true});
for (const t of ['diff-map', 'side-by-side']) {
	const bin = path.join(TOOLS, t), src = path.join(ROOT, 'tools', t + '.swift');
	if (!fs.existsSync(bin) || fs.statSync(src).mtimeMs > fs.statSync(bin).mtimeMs) spawnSync('swiftc', ['-O', src, '-o', bin], {stdio: 'inherit'});
}
const chrome = opt.chrome ?? process.env.METALREEL_CHROME;
const sh = (cmd, args, cwd = ROOT) => { const r = spawnSync(cmd, args, {cwd, encoding: 'utf8'}); if (r.status !== 0) { process.stderr.write(r.stderr.slice(-2000)); throw new Error(`${cmd} ${args.join(' ')} failed`); } return r.stdout + r.stderr; };
const results = [];
for (const it of items) {
	const [comp, frames] = it.split(':');
	for (const f of frames.split(',').map(Number)) {
		const base = path.join(OUT, `${comp}-${f}`);
		const ref = base + '-remotion.png', nat = base + '-native.png', hyb = base + '-hybrid.png';
		process.stderr.write(`${comp} @ ${f}\n`);
		sh('npx', ['remotion', 'still', comp, ref, `--frame=${f}`, '--log=error', ...(chrome ? [`--browser-executable=${chrome}`] : [])], PROJECT);
		sh(process.execPath, [path.join(ROOT, 'js/cli/metalreel.mjs'), 'still', comp, '--project', PROJECT, '--frame', String(f), '--png', nat]);
		const row = {comp, frame: f, native: +/MAE=([\d.]+)/.exec(sh(path.join(TOOLS, 'diff-map'), [nat, ref, base + '-diff-native.png']))[1]};
		sh(path.join(TOOLS, 'side-by-side'), [nat, ref, base + '-sbs.png', '0', '0', '99999', '99999', '0.5', 'MetalReel native', 'Remotion (Chrome)']);
		if (opt.hybrid) {
			sh(process.execPath, [path.join(ROOT, 'js/cli/metalreel.mjs'), 'still', comp, '--project', PROJECT, '--frame', String(f), '--png', hyb, '--mode', 'hybrid', ...(chrome ? ['--chrome', chrome] : [])]);
			row.hybrid = +/MAE=([\d.]+)/.exec(sh(path.join(TOOLS, 'diff-map'), [hyb, ref, base + '-diff-hybrid.png']))[1];
		}
		results.push(row);
		process.stderr.write(`  MAE native ${row.native}${row.hybrid != null ? `, hybrid ${row.hybrid}` : ''}\n`);
	}
}
fs.writeFileSync(path.join(OUT, 'results.json'), JSON.stringify(results, null, 2));
const md = ['| Composition | Frame | MAE native | MAE hybrid |', '|---|---|---|---|', ...results.map((r) => `| ${r.comp} | ${r.frame} | ${r.native.toFixed(2)} | ${r.hybrid != null ? r.hybrid.toFixed(2) : '–'} |`)].join('\n');
fs.writeFileSync(path.join(OUT, 'results.md'), md + '\n\nMAE = mean absolute difference per RGB channel on a 0–255 scale, measured against `npx remotion still` (Chrome).\n');
console.log(md);
