// Hybrid mode front end (Chrome side). Drives the Remotion bundle in headless Chrome frame by frame
// without taking screenshots, and extracts each frame's display list via CDP DOMSnapshot: boxes, gradients,
// shadows, images, video timestamps, text lines and audio assets. Elements that cannot be drawn natively
// (SVG, canvas, clip-path, mask, non-native filters) are rendered only for that element as cached PNGs.
// Output is NDJSON, one line per frame, consumed by `metalreel draw`.
//
// node extract.mjs --bundle <dir> --comp X --start 0 --count N --tabs 12 --w 1080 --h 1920 --fps 30 [--props '<serialized>'] --chrome <path> | metalreel draw --out x.mp4
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import puppeteer from 'puppeteer-core';
import {STYLES_LIST as STYLES} from './styles.mjs';

const args = Object.fromEntries(process.argv.slice(2).reduce((a, v, i, arr) => (v.startsWith('--') ? [...a, [v.slice(2), arr[i + 1]]] : a), []));
if (args.comp === undefined) { process.stderr.write('--comp <composition id> is required\n'); process.exit(1); }
const CHROME = args.chrome ?? process.env.METALREEL_CHROME;
if (CHROME === undefined) { process.stderr.write('--chrome <path to chrome-headless-shell> is required (or set METALREEL_CHROME)\n'); process.exit(1); }
const START = +(args.start ?? 0);
const COUNT = +(args.count ?? 300);
const TABS = +(args.tabs ?? 8);
const COMP = {id: args.comp, width: +(args.w ?? 1080), height: +(args.h ?? 1920), fps: +(args.fps ?? 30), durationInFrames: +(args.dur ?? 999999)};
const PROPS = args.props ?? '{}';
const HERE = path.dirname(new URL(import.meta.url).pathname);
const BUNDLE = path.resolve(args.bundle ?? path.join(HERE, 'bundle'));
const RASTER_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'metalreel-raster-'));
const log = (...a) => process.stderr.write(a.join(' ') + '\n');
const warnings = new Map();
const extraWaits = new Map(); // tab → number of extra waits caused by stale frames
const warn = (s) => warnings.set(s, (warnings.get(s) ?? 0) + 1);

// ── static server + OffthreadVideo /proxy stand-in (no video frames are extracted) ──
const PNG1 = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64');
const MIME = {'.html': 'text/html', '.js': 'application/javascript', '.json': 'application/json', '.png': 'image/png', '.css': 'text/css', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.mp3': 'audio/mpeg', '.wav': 'audio/wav', '.mp4': 'video/mp4'};
const server = http.createServer((req, res) => {
	const u = new URL(req.url, 'http://x');
	if (u.pathname === '/proxy') {
		res.writeHead(200, {'content-type': 'image/png', 'content-length': PNG1.length, 'access-control-allow-origin': '*', 'cache-control': 'no-store'});
		return res.end(PNG1);
	}
	const p = u.pathname === '/' ? path.join(BUNDLE, 'index.html') : path.join(BUNDLE, decodeURIComponent(u.pathname));
	fs.stat(p, (err, st) => {
		if (err || !st.isFile()) { res.writeHead(404); return res.end(); }
		res.writeHead(200, {'content-type': MIME[path.extname(p).toLowerCase()] ?? 'application/octet-stream', 'content-length': st.size, 'access-control-allow-origin': '*'});
		fs.createReadStream(p).pipe(res);
	});
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const PORT = server.address().port;
const ORIGIN = `http://127.0.0.1:${PORT}`;
const toLocalPath = (url) => {
	if (!url) return url;
	if (url.startsWith('file://')) return decodeURIComponent(new URL(url).pathname);
	if (!url.startsWith(ORIGIN)) return url;
	const p = path.join(BUNDLE, decodeURIComponent(new URL(url).pathname));
	try { return fs.realpathSync(p); } catch { return p; }
};

const browser = await puppeteer.launch({
	executablePath: CHROME, headless: 'shell',
	args: ['--no-sandbox', '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows',
		'--font-render-hinting=none', '--force-color-profile=srgb', '--hide-scrollbars', '--mute-audio', '--disable-ipc-flooding-protection',
		'--disable-features=IsolateOrigins,site-per-process,LocalNetworkAccessChecks,BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights'],
	defaultViewport: {width: COMP.width, height: COMP.height, deviceScaleFactor: 1},
	protocolTimeout: 120000,
});

async function makeTab(initialFrame) {
	const page = await browser.newPage();
	page.on('pageerror', (e) => log('[pageerror]', e.message));
	await page.evaluateOnNewDocument((port, f0, props) => {
		window.remotion_puppeteerTimeout = 60000; window.remotion_isMainTab = true;
		window.remotion_mediaCacheSizeInBytes = 1e9; window.remotion_initialMemoryAvailable = 8e9; window.remotion_sampleRate = 48000;
		window.process = window.process || {}; window.process.env = window.process.env || {}; window.process.env.NODE_ENV = 'production';
		window.remotion_inputProps = props; window.remotion_initialFrame = f0; window.remotion_attempt = 1; window.remotion_proxyPort = port;
		window.remotion_audioEnabled = true; window.remotion_videoEnabled = true; window.remotion_logLevel = 'warn';
		window.__blobInfo = {};
		// capture the font files Remotion loads (the Swift side uses the same files)
		window.__fonts = [];
		const abUrl = new WeakMap();
		const origAB = Response.prototype.arrayBuffer;
		Response.prototype.arrayBuffer = async function () { const b = await origAB.call(this); abUrl.set(b, this.url); return b; };
		const OrigFF = window.FontFace;
		const YeniFF = function (family, source, desc) {
			const ff = new OrigFF(family, source, desc);
			let url = null, b64 = null;
			if (typeof source === 'string') { const m = source.match(/url\(["']?([^"')]+)["']?\)/); url = m ? new URL(m[1], location.href).href : null; }
			else if (source) { url = abUrl.get(source.buffer ?? source) ?? null; if (!url) { const u8 = new Uint8Array(source.buffer ?? source); let t = ''; for (let i = 0; i < u8.length; i += 8192) t += String.fromCharCode.apply(null, u8.subarray(i, i + 8192)); b64 = btoa(t); } }
			window.__fonts.push({family: String(family).replace(/^["']|["']$/g, ''), url, b64, w: String(desc?.weight ?? 'normal'), s: String(desc?.style ?? 'normal'), u: String(desc?.unicodeRange ?? '')});
			return ff;
		};
		YeniFF.prototype = OrigFF.prototype;
		window.FontFace = YeniFF;
		const blobSrc = new WeakMap();
		const origBlob = Response.prototype.blob;
		Response.prototype.blob = async function () { const b = await origBlob.call(this); if (this.url.includes('/proxy?')) blobSrc.set(b, this.url); return b; };
		const origCreate = URL.createObjectURL;
		URL.createObjectURL = function (b) {
			const u = origCreate.call(URL, b); const p = blobSrc.get(b);
			if (p) { const q = new URL(p).searchParams; window.__blobInfo[u] = {src: q.get('src'), time: +q.get('time')}; }
			return u;
		};
	}, PORT, initialFrame, PROPS);
	await page.goto(`${ORIGIN}/index.html`, {waitUntil: 'load'});
	await page.evaluate((c, props) => {
		window.remotion_setBundleMode({
			type: 'composition', compositionName: c.id, serializedResolvedPropsWithSchema: props,
			compositionDurationInFrames: c.durationInFrames, compositionFps: c.fps, compositionHeight: c.height, compositionWidth: c.width,
			compositionDefaultCodec: 'h264', compositionDefaultOutName: 'out', compositionDefaultVideoImageFormat: 'jpeg',
			compositionDefaultPixelFormat: 'yuv420p', compositionDefaultProResProfile: null, compositionDefaultSampleRate: 48000,
		});
		// hide style so that only the non-native element is drawn
		const s = document.createElement('style');
		s.textContent = 'html.__mr *{visibility:hidden!important} html.__mr [data-mr],html.__mr [data-mr] *{visibility:visible!important} html.__mr,html.__mr body{background:transparent!important}';
		document.head.appendChild(s);
	}, COMP, PROPS);
	await page.waitForFunction('window.remotion_renderReady === true', {polling: 'raf', timeout: 60000});
	const cdp = await page.createCDPSession();
	await cdp.send('Emulation.setDefaultBackgroundColorOverride', {color: {r: 0, g: 0, b: 0, a: 0}});
	return {page, cdp};
}

// set the frame and wait until it is ready (microtask + 2 ticks against the React 19 stale-frame race); collect audio/video assets
const seek = (page, f, fontCount) => page.evaluate(async (f, id, fontCount) => {
	window.remotion_setFrame(f, id, 1);
	const tick = () => new Promise((r) => { const mc = new MessageChannel(); mc.port1.onmessage = () => r(); mc.port2.postMessage(0); });
	await null; await null; await tick(); await tick();
	const ready = () => new Promise((res, rej) => {
		const chk = () => {
			if (window.remotion_cancelledError) return rej(new Error(window.remotion_cancelledError));
			if (window.remotion_renderReady === true) return res();
			requestAnimationFrame(chk);
		};
		chk();
	});
	// Stale-frame guard: under load React may process the new frame after Remotion's rAF, so renderReady turns true early
	// and the video stays on the previous frame (a "freeze" as many ticks as there are tabs).
	// Media assets carry their own frame (a.frame): they all belong to this frame; wait until the images have loaded.
	const raw = [];
	for (let k = 0; ; k++) {
		await ready();
		await document.fonts.ready;
		const newAssets = window.remotion_collectAssets ? window.remotion_collectAssets() : [];
		raw.push(...newAssets.filter((a) => a.frame === f));
		const stale = (newAssets.length > 0 && !newAssets.some((a) => a.frame === f)) || [...document.images].some((i) => !i.complete);
		if (!stale) break;
		if (k >= 60) { window.__stale = (window.__stale ?? 0) + 1; break; }
		window.__extra = (window.__extra ?? 0) + 1;
		await tick(); await new Promise((r) => requestAnimationFrame(r)); await tick();
	}
	const assets = raw
		.filter((a) => a.type === 'audio' || a.type === 'video')
		.map((a) => ({id: a.id, src: a.src, frame: a.frame, v: a.volume, mf: a.mediaFrame, pr: a.playbackRate, si: a.audioStreamIndex}));
	// @font-face rules (those loaded via CSS)
	const css = [];
	for (const ss of document.styleSheets) { let rules = []; try { rules = [...ss.cssRules]; } catch {} for (const r of rules) if (r instanceof CSSFontFaceRule) {
		const m = r.style.getPropertyValue('src').match(/url\(["']?([^"')]+)["']?\)/);
		if (m) css.push({family: r.style.getPropertyValue('font-family').replace(/^["']|["']$/g, ''), url: new URL(m[1], ss.href ?? location.href).href, w: r.style.getPropertyValue('font-weight') || 'normal', s: r.style.getPropertyValue('font-style') || 'normal', u: r.style.getPropertyValue('unicode-range') || ''});
	} }
	const allFonts = [...window.__fonts, ...css];
	return {blobInfo: window.__blobInfo, assets, fonts: allFonts.length !== fontCount ? allFonts : null, stale: window.__stale ?? 0, extra: window.__extra ?? 0};
}, f, COMP.id, fontCount);

// ── DOMSnapshot → simple display list ────────────────────────────────────────
const px = (v) => (v == null ? NaN : parseFloat(v));
const splitTopLevelCommas = (s) => { const out = []; let d = 0, cur = ''; for (const ch of s) { if (ch === '(') d++; if (ch === ')') d--; if (ch === ',' && d === 0) { out.push(cur.trim()); cur = ''; } else cur += ch; } if (cur.trim()) out.push(cur.trim()); return out; };
const shadows = (s, k) => (!s || s === 'none') ? null : splitTopLevelCommas(s).map((g) => {
	const color = (g.match(/rgba?\([^)]*\)/) || ['rgba(0, 0, 0, 1)'])[0];
	const n = g.replace(color, '').replace('inset', '').trim().split(/\s+/).map(parseFloat);
	return {c: color, x: (n[0] || 0) * k, y: (n[1] || 0) * k, b: (n[2] || 0) * k, s: (n[3] || 0) * k, ic: g.includes('inset')};
});
/** CSS transform to linear part [a,b,c,d] */
const parseMatrix = (t) => {
	if (!t || t === 'none') return [1, 0, 0, 1];
	const n = t.slice(t.indexOf('(') + 1, -1).split(',').map(parseFloat);
	if (t.startsWith('matrix3d')) { if (Math.abs(n[2]) > 1e-6 || Math.abs(n[6]) > 1e-6 || Math.abs(n[3]) > 1e-6 || Math.abs(n[7]) > 1e-6) warn('3D transform (approximated)'); return [n[0], n[1], n[4], n[5]]; }
	return [n[0], n[1], n[2], n[3]];
};
const multiply = (p, m) => [p[0] * m[0] + p[2] * m[1], p[1] * m[0] + p[3] * m[1], p[0] * m[2] + p[2] * m[3], p[1] * m[2] + p[3] * m[3]];
const isRotated = (L) => Math.abs(L[1]) > 1e-4 || Math.abs(L[2]) > 1e-4;
/** solve the unrotated local size from the bounding box (bbox): W = |a|w + |c|h, H = |b|w + |d|h */
const localSize = (L, bw, bh) => {
	const A = Math.abs(L[0]), B = Math.abs(L[1]), C = Math.abs(L[2]), D = Math.abs(L[3]);
	const det = A * D - C * B;
	if (Math.abs(det) < 1e-3) return [bw / Math.max(1e-6, Math.hypot(L[0], L[1])), bh / Math.max(1e-6, Math.hypot(L[2], L[3]))];
	return [(D * bw - C * bh) / det, (A * bh - B * bw) / det];
};
const LOCAL_FILTERS = new Set(['blur', 'brightness', 'contrast', 'saturate', 'grayscale', 'sepia', 'hue-rotate', 'invert', 'opacity']);

function simplify(snap, blobInfo) {
	const S = snap.strings, doc = snap.documents[0], N = doc.nodes, L = doc.layout, TB = doc.textBoxes;
	const PO = L.paintOrders || [];
	const sty = (li) => { const o = {}; L.styles[li].forEach((si, k) => { if (si >= 0) o[STYLES[k]] = S[si]; }); return o; };
	const srcOf = (ni) => { const r = N.currentSourceURL ? N.currentSourceURL.index.indexOf(ni) : -1; return r >= 0 ? S[N.currentSourceURL.value[r]] : null; };
	const textBoxesByLayout = new Map();
	for (let b = 0; b < TB.layoutIndex.length; b++) {
		const li = TB.layoutIndex[b];
		if (!textBoxesByLayout.has(li)) textBoxesByLayout.set(li, []);
		textBoxesByLayout.get(li).push(b);
	}
	const info = new Map(); // node -> {o, clip, k, hidden, st, L, ras, fl, bm}
	const ops = [], rasters = [];
	const root = {o: 1, clip: [], k: 1, hidden: false, st: {}, L: [1, 0, 0, 1], ras: false, fl: [], bm: undefined};
	// elements containing video cannot be drawn by Chrome (video stand-in), so their effects are applied natively
	const videoAncestors = new Set();
	if (N.currentSourceURL) N.currentSourceURL.index.forEach((ni, j) => { if (blobInfo[S[N.currentSourceURL.value[j]]]) { for (let a = ni; a >= 0; a = N.parentIndex[a]) videoAncestors.add(a); } });
	const order = L.nodeIndex.map((ni, li) => [ni, li]).sort((a, b) => a[0] - b[0]);
	for (const [ni, li] of order) {
		let p = N.parentIndex[ni];
		while (p >= 0 && !info.has(p)) p = N.parentIndex[p];
		const pi = p >= 0 ? info.get(p) : root;
		const b = L.bounds[li];
		if (pi.ras) { info.set(ni, pi); continue; } // inside an element drawn by Chrome
		if (N.nodeType[ni] === 3) { // text: line by line, with the parent's style
			if (pi.hidden || pi.o < 0.002) continue;
			const st = pi.st, txt = S[L.text[li]] ?? '';
			const rot = isRotated(pi.L);
			for (const tb of textBoxesByLayout.get(li) ?? []) {
				const r = TB.bounds[tb], s = txt.substr(TB.start[tb], TB.length[tb]);
				if (!s.trim()) continue;
				const op = {t: 'x', p: PO[li] ?? 0, d: ni, b: r, s, ff: st['font-family'], fw: +st['font-weight'] || 400, fs: px(st['font-size']) * (rot ? 1 : pi.k),
					fi: st['font-style'] === 'italic' ? 1 : 0, col: st.color, ls: (px(st['letter-spacing']) || 0) * (rot ? 1 : pi.k), o: pi.o, c: pi.clip};
				if (st['text-shadow'] && st['text-shadow'] !== 'none') op.ts = shadows(st['text-shadow'], rot ? 1 : pi.k);
				if (rot) { op.m = pi.L; op.lb = localSize(pi.L, r[2], r[3]); }
				if (pi.fl.length) op.fl = pi.fl;
				if (pi.bm) op.bm = pi.bm;
				ops.push(op);
			}
			continue;
		}
		const st = sty(li);
		const tag = S[N.nodeName[ni]];
		const hidden = pi.hidden || st.visibility === 'hidden' || st.display === 'none';
		const o = pi.o * (st.opacity != null ? +st.opacity : 1);
		const Lm = multiply(pi.L, parseMatrix(st.transform));
		const w = px(st.width), h = px(st.height);
		const rot = isRotated(Lm);
		const k = rot ? 1 : (w > 0 && b[2] > 0 && /px$/.test(st.width) ? b[2] / w : pi.k);
		const r = (px(st['border-top-left-radius']) || 0) * k;
		// effects: color filters and blur are native (inherited by child elements); blend mode is applied at compositing;
		// everything else is drawn by Chrome for this element only
		const flt = st.filter && st.filter !== 'none' ? st.filter : null;
		const fls = flt ? (flt.match(/[a-z-]+\([^)]*\)/g) ?? []) : [];
		const localFilter = fls.every((f) => LOCAL_FILTERS.has(f.slice(0, f.indexOf('('))));
		const blendMode = st['mix-blend-mode'] && st['mix-blend-mode'] !== 'normal' ? st['mix-blend-mode'] : undefined;
		const video = videoAncestors.has(ni);
		const reason = tag.toLowerCase() === 'svg' ? 'SVG' : tag === 'CANVAS' ? 'canvas' : (flt && !localFilter) ? `filter ${fls.find((f) => !LOCAL_FILTERS.has(f.slice(0, f.indexOf('(')))) ?? flt}`
			: (st['clip-path'] && st['clip-path'] !== 'none') ? 'clip-path' : ((st['mask-image'] && st['mask-image'] !== 'none') || (st['-webkit-mask-image'] && st['-webkit-mask-image'] !== 'none')) ? 'mask'
			: null;
		if (reason && video) warn(`${reason} on a video-containing element — ignored`);
		if (reason && !video && !hidden && o >= 0.002 && b[2] > 0 && b[3] > 0) {
			warn(`drawn by Chrome: ${reason}`);
			const x0 = Math.max(0, Math.floor(b[0])), y0 = Math.max(0, Math.floor(b[1]));
			const x1 = Math.min(COMP.width, Math.ceil(b[0] + b[2])), y1 = Math.min(COMP.height, Math.ceil(b[1] + b[3]));
			info.set(ni, {...pi, ras: true});
			if (x1 > x0 && y1 > y0) {
				const op = {t: 'g', p: PO[li] ?? 0, d: ni, b: [x0, y0, x1 - x0, y1 - y0], bn: N.backendNodeId[ni], digest: JSON.stringify([b, o, Lm, pi.clip, st.opacity, st.transform, st.filter, st['clip-path'], st['mask-image'] ?? st['-webkit-mask-image']])};
				if (blendMode || pi.bm) op.bm = blendMode ?? pi.bm;
				if (pi.fl.length) op.fl = pi.fl;
				ops.push(op); rasters.push(op);
			}
			continue;
		}
		const fl = flt && localFilter ? [...pi.fl, ...fls.map((f) => f.startsWith('blur(') ? `blur(${px(f.slice(5)) * k}px)` : f)] : pi.fl;
		const bm = blendMode ?? pi.bm;
		if (blendMode) warn(`blend mode: ${blendMode}`);
		const ovf = st.overflow === 'hidden' || st.overflow === 'clip' || st['overflow-x'] === 'hidden' || st['overflow-x'] === 'clip';
		const clip = ovf && tag !== 'IMG' && tag !== 'VIDEO' ? [...pi.clip, [b[0], b[1], b[2], b[3], rot ? 0 : r]] : pi.clip;
		info.set(ni, {o, clip, k, hidden, st, L: Lm, ras: false, fl, bm});
		if (hidden || o < 0.002 || b[2] <= 0 || b[3] <= 0 || b[1] > COMP.height || b[1] + b[3] < 0 || b[0] > COMP.width || b[0] + b[2] < 0) continue;
		const bg = st['background-color'] && st['background-color'] !== 'rgba(0, 0, 0, 0)' ? st['background-color'] : undefined;
		let gi = st['background-image'] && st['background-image'] !== 'none' ? st['background-image'] : undefined;
		if (gi && gi.startsWith('url(')) { warn('background-image url (unsupported)'); gi = undefined; }
		const sh = shadows(st['box-shadow'], k);
		const bw = px(st['border-top-width']) || 0;
		const br = bw > 0 && st['border-top-style'] !== 'none' ? {w: bw * k, c: st['border-top-color']} : undefined;
		const push = (op) => { if (fl.length) op.fl = fl; if (bm) op.bm = bm; if (rot) { op.m = Lm; op.lb = [w > 0 ? w : localSize(Lm, b[2], b[3])[0], h > 0 ? h : localSize(Lm, b[2], b[3])[1]]; } ops.push(op); };
		const bf = st['backdrop-filter'] && st['backdrop-filter'] !== 'none' ? (st['backdrop-filter'].match(/[a-z-]+\([^)]*\)/g) ?? []).filter((f) => LOCAL_FILTERS.has(f.slice(0, f.indexOf('(')))) : null;
		if (bg || gi || sh || br || bf) push({t: 'r', p: PO[li] ?? 0, d: ni, b, r, bg, gi, sh, br, bf: bf?.length ? bf : undefined, o, c: pi.clip});
		if (tag === 'IMG' || tag === 'VIDEO') {
			const src = srcOf(ni) || null;
			const v = src && blobInfo[src];
			const op = {t: 'i', p: PO[li] ?? 0, d: ni + 0.5, b, r, fit: st['object-fit'] || 'fill', o, c: pi.clip};
			if (v) op.v = {src: toLocalPath(v.src), time: v.time};
			else if (src && !src.startsWith('blob:') && !src.startsWith('data:')) op.src = toLocalPath(src);
			else if (src && src.startsWith('data:')) { warn('data: URL image'); continue; }
			else continue;
			push(op);
		}
	}
	ops.sort((a, b) => a.p - b.p || a.d - b.d);
	for (const op of ops) { delete op.p; delete op.d; }
	return {ops, rasters};
}

// draw only this element with a transparent background → PNG file (the same content is not written again)
const rasterCache = new Map();
async function rasterize(cdp, page, op) {
	const {object} = await cdp.send('DOM.resolveNode', {backendNodeId: op.bn});
	// if the same content + same position/opacity was drawn before, do not draw it again (e.g. a spinning gear every 24 frames)
	const {result} = await cdp.send('Runtime.callFunctionOn', {objectId: object.objectId, returnByValue: true,
		functionDeclaration: 'function(){let s=this.outerHTML;for(let a=this.parentElement;a;a=a.parentElement)s+="|"+a.getAttribute("style");return s}'});
	const signature = crypto.createHash('sha1').update(op.digest + result.value).digest('hex');
	delete op.digest;
	const previous = rasterSignatures.get(signature);
	if (previous) { op.png = await previous; delete op.bn; await cdp.send('Runtime.releaseObject', {objectId: object.objectId}); rasterHits++; return; }
	let finish; rasterSignatures.set(signature, new Promise((r) => (finish = r)));
	await cdp.send('Runtime.callFunctionOn', {objectId: object.objectId, functionDeclaration: 'function(){this.setAttribute("data-mr","1");document.documentElement.classList.add("__mr")}'});
	const {data} = await cdp.send('Page.captureScreenshot', {format: 'png', clip: {x: op.b[0], y: op.b[1], width: op.b[2], height: op.b[3], scale: 1}, captureBeyondViewport: false, fromSurface: true});
	await cdp.send('Runtime.callFunctionOn', {objectId: object.objectId, functionDeclaration: 'function(){this.removeAttribute("data-mr");document.documentElement.classList.remove("__mr")}'});
	await cdp.send('Runtime.releaseObject', {objectId: object.objectId});
	const h = crypto.createHash('sha1').update(data).digest('hex');
	let file = rasterCache.get(h);
	if (!file) { file = path.join(RASTER_DIR, h + '.png'); fs.writeFileSync(file, Buffer.from(data, 'base64')); rasterCache.set(h, file); }
	rasterDraws++;
	op.png = file; delete op.bn; finish(file);
}
const rasterSignatures = new Map();
let rasterHits = 0, rasterDraws = 0;

// ── fonts: download each unique face to a local file, report to Swift line by line ───────
const FONT_DIR = path.join(path.dirname(BUNDLE), 'fontlar'); fs.mkdirSync(FONT_DIR, {recursive: true});
const seenFonts = new Map(); // key → face
async function prepareFonts(list) {
	const fresh = [];
	for (const f of list) {
		const key = `${f.family}|${f.w}|${f.s}|${f.u}|${f.url ?? (f.b64 ?? '').slice(0, 64)}`;
		if (seenFonts.has(key)) continue;
		seenFonts.set(key, null);
		let file = null;
		try {
			if (f.url && f.url.startsWith(ORIGIN)) file = toLocalPath(f.url);
			else {
				const h = crypto.createHash('sha1').update(f.url ?? f.b64).digest('hex');
				const ext = (f.url && path.extname(new URL(f.url).pathname)) || '.font';
				file = path.join(FONT_DIR, h + ext);
				if (!fs.existsSync(file)) fs.writeFileSync(file, f.url ? Buffer.from(await (await fetch(f.url)).arrayBuffer()) : Buffer.from(f.b64, 'base64'));
			}
		} catch (e) { warn(`font download failed: ${f.family}`); continue; }
		const face = {family: f.family, path: file, w: f.w, s: f.s, u: f.u};
		seenFonts.set(key, face); fresh.push(face);
	}
	return fresh;
}

// ── tabs take frames at intervals; the writer dumps them to stdout in order ─────────────
const pending = new Map();
let nextFrame = START, written = 0;
const T0 = performance.now();
const write = () => {
	while (pending.has(nextFrame)) {
		const line = pending.get(nextFrame); pending.delete(nextFrame);
		process.stdout.write(line + '\n');
		nextFrame++; written++;
		if (written % 600 === 0) log(`  chrome: ${written}/${COUNT} frames, ${(written / ((performance.now() - T0) / 1000)).toFixed(1)} fps`);
	}
};
process.stdout.write(JSON.stringify({w: COMP.width, h: COMP.height, fps: COMP.fps, start: START, count: COUNT}) + '\n');

async function tab(k) {
	const frames = []; for (let f = START + k; f < START + COUNT; f += TABS) frames.push(f);
	if (!frames.length) return;
	const {page, cdp} = await makeTab(frames[0]);
	let fontCount = -1;
	for (const f of frames) {
		while (f - nextFrame > 4 * TABS || process.stdout.writableLength > 8e6) await new Promise((r) => setTimeout(r, 5));
		const {blobInfo, assets, fonts, stale, extra} = await seek(page, f, fontCount); if (stale) warn('stale frame (wait limit)'); extraWaits.set(page, extra);
		let newFonts = [];
		if (fonts) { fontCount = fonts.length; newFonts = await prepareFonts(fonts); }
		// the font line is written immediately, without waiting for ordering: no frame using this font can have been written before it
		if (newFonts.length) process.stdout.write(JSON.stringify({fonts: newFonts}) + '\n');
		const snap = await cdp.send('DOMSnapshot.captureSnapshot', {computedStyles: STYLES, includePaintOrder: true, includeDOMRects: false});
		const {ops, rasters} = simplify(snap, blobInfo);
		for (const op of rasters) await rasterize(cdp, page, op);
		for (const a of assets) a.src = toLocalPath(a.src);
		pending.set(f, JSON.stringify({f, ops, a: assets.length ? assets : undefined}));
		write();
	}
	await page.close();
}
await Promise.all(Array.from({length: TABS}, (_, k) => tab(k)));
log(`  chrome done: ${COUNT} frames, ${((performance.now() - T0) / 1000).toFixed(2)} s`);
for (const [s, n] of warnings) log(`  [warning] ${s} (${n} times)`);
log(`  stale frame guard: ${[...extraWaits.values()].reduce((a, b) => a + b, 0)} extra waits`);
if (rasterDraws + rasterHits) log(`  Chrome-drawn elements: ${rasterDraws} drawn, ${rasterHits} from cache`);
await browser.close();
server.close();
