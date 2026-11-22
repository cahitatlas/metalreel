#!/usr/bin/env node
// Turns bench/results/results.json into README charts: docs/img/speed.svg (frames per second) and
// docs/img/cpu.svg (CPU seconds spent per rendered minute of video).
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const {machine, results} = JSON.parse(fs.readFileSync(path.join(ROOT, 'bench/results/results.json'), 'utf8'));
const comps = [...new Set(results.map((r) => r.comp))];
const MODES = [['remotion', 'Remotion (Chrome)', '#94a3b8'], ['hybrid', 'MetalReel hybrid', '#38bdf8'], ['native', 'MetalReel native', '#7c3aed']];
const get = (c, m) => results.find((r) => r.comp === c && r.mode === m);
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');

function chart({file, title, subtitle, value, unit, better}) {
	const rowH = 18, groupGap = 22, left = 190, right = 90, top = 96, W = 1000;
	const max = Math.max(...results.map(value)) * 1.08;
	const H = top + comps.length * (MODES.length * rowH + groupGap) + 40;
	const x = (v) => left + (v / max) * (W - left - right);
	let y = top, body = '';
	for (const c of comps) {
		body += `<text x="${left - 14}" y="${y + (MODES.length * rowH) / 2 + 5}" text-anchor="end" font-size="14" font-weight="600" fill="#0f172a">${esc(c)}</text>`;
		for (const [m, , color] of MODES) {
			const r = get(c, m); if (!r) { y += rowH; continue; }
			const v = value(r);
			body += `<rect x="${left}" y="${y + 2}" width="${Math.max(2, x(v) - left)}" height="${rowH - 4}" rx="3" fill="${color}"/>`;
			const base = get(c, 'remotion');
			const extra = m !== 'remotion' && base ? (better === 'higher' ? ` · ${(v / value(base)).toFixed(1)}×` : ` · ${(value(base) / Math.max(v, 1e-9)).toFixed(0)}× less`) : '';
			body += `<text x="${x(v) + 6}" y="${y + rowH - 5}" font-size="12" fill="#334155">${v >= 100 ? Math.round(v) : v.toFixed(1)} ${unit}${extra}</text>`;
			y += rowH;
		}
		y += groupGap;
	}
	const legend = MODES.map(([, label, color], i) => `<rect x="${left + i * 190}" y="62" width="14" height="14" rx="3" fill="${color}"/><text x="${left + 20 + i * 190}" y="74" font-size="13" fill="#334155">${label}</text>`).join('');
	const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif">
<rect width="${W}" height="${H}" rx="16" fill="#ffffff"/><rect x="0.5" y="0.5" width="${W - 1}" height="${H - 1}" rx="16" fill="none" stroke="#e2e8f0"/>
<text x="24" y="34" font-size="20" font-weight="700" fill="#0f172a">${esc(title)}</text><text x="24" y="54" font-size="13" fill="#64748b">${esc(subtitle)} · ${esc(machine)}</text>
${legend}${body}</svg>\n`;
	fs.writeFileSync(path.join(ROOT, 'docs/img', file), svg);
}
chart({file: 'speed.svg', title: 'Render speed (frames per second, higher is better)', subtitle: 'wall clock incl. startup, measured', value: (r) => r.fps, unit: 'fps', better: 'higher'});
chart({file: 'cpu.svg', title: 'CPU time per minute of video (lower is better)', subtitle: 'user + sys CPU seconds, measured', value: (r) => (r.cpu / r.frames) * 30 * 60, unit: 's', better: 'lower'});
console.log('wrote docs/img/speed.svg and docs/img/cpu.svg');
