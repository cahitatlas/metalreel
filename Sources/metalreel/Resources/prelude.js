// MetalReel prelude — evaluated in JavaScriptCore before the Remotion bundle.
//
// JavaScriptCore is a bare ECMAScript engine: no DOM, no timers, no fetch. This file provides just
// enough of the browser for Remotion's runtime and typical compositions:
//   • an event loop (setTimeout/setInterval/setImmediate/requestAnimationFrame/MessageChannel) that
//     Swift drives one task at a time, so microtasks drain between tasks exactly like in a browser;
//   • a small DOM (elements, text nodes, style objects, attributes, events) used as React host nodes;
//   • fetch / Blob / URL / FontFace / document.fonts backed by native Swift functions (`__mr`);
//   • `__mr_snapshot()` which serializes the composition tree once per frame for native layout.
// Nothing here paints. Swift owns layout (Yoga), text (Core Text) and drawing (Metal).
(function () {
	'use strict';
	const G = globalThis;
	const N = G.__mr; // native bridge, installed by Swift
	G.window = G; G.self = G; G.top = G; G.parent = G; G.frames = G;

	// ── console ────────────────────────────────────────────────────────────────
	const fmt = (a) => a.map((x) => (typeof x === 'string' ? x : x instanceof Error ? (x.stack ? x.message + '\n' + x.stack : x.message) : (() => { try { return JSON.stringify(x); } catch { return String(x); } })())).join(' ');
	G.console = {
		log: (...a) => N.log('log', fmt(a)), info: (...a) => N.log('info', fmt(a)), debug: (...a) => N.log('debug', fmt(a)),
		warn: (...a) => N.log('warn', fmt(a)), error: (...a) => N.log('error', fmt(a)), trace: (...a) => N.log('debug', fmt(a)),
		group() {}, groupCollapsed() {}, groupEnd() {}, time() {}, timeEnd() {}, table: (...a) => N.log('log', fmt(a)), assert: (c, ...a) => { if (!c) N.log('error', 'Assertion failed ' + fmt(a)); },
	};

	// ── event loop ─────────────────────────────────────────────────────────────
	const tasks = []; // macrotasks, FIFO
	const timers = new Map(); // id → {due, fn, args, every}
	let rafs = new Map(); let rafId = 0; let timerId = 0;
	const now = () => N.now();
	const run = (fn, args) => { try { fn(...args); } catch (e) { G.__mr_lastError = e; console.error(e); } };
	G.setTimeout = (fn, ms = 0, ...args) => { const id = ++timerId; if (typeof fn !== 'function') { const src = String(fn); fn = () => (0, eval)(src); } timers.set(id, {due: now() + Math.max(0, +ms || 0), fn, args, every: null}); return id; };
	G.setInterval = (fn, ms = 0, ...args) => { const id = ++timerId; const every = Math.max(1, +ms || 0); timers.set(id, {due: now() + every, fn, args, every}); return id; };
	G.clearTimeout = G.clearInterval = (id) => { timers.delete(id); };
	G.setImmediate = (fn, ...args) => { const id = ++timerId; tasks.push({id, fn, args}); return id; };
	G.clearImmediate = (id) => { const i = tasks.findIndex((t) => t.id === id); if (i >= 0) tasks.splice(i, 1); };
	G.queueMicrotask = (fn) => { Promise.resolve().then(fn); };
	G.requestAnimationFrame = (fn) => { const id = ++rafId; rafs.set(id, fn); return id; };
	G.cancelAnimationFrame = (id) => { rafs.delete(id); };
	G.requestIdleCallback = (fn) => G.setTimeout(() => fn({didTimeout: false, timeRemaining: () => 50}), 1);
	G.cancelIdleCallback = G.clearTimeout;
	/**
	 * Run ONE unit of work and return.
	 *   0  → ran something (call again)
	 *   >0 → nothing runnable; milliseconds until the next timer is due
	 *   -1 → completely idle (no timers, no tasks, no animation frames)
	 * Swift calls this in a loop; JavaScriptCore drains the microtask queue after each call.
	 */
	G.__mr_step = () => {
		if (tasks.length) { const t = tasks.shift(); run(t.fn, t.args); return 0; }
		const t = now();
		let next = Infinity, nextId = -1;
		for (const [id, tm] of timers) if (tm.due < next) { next = tm.due; nextId = id; }
		if (nextId >= 0 && next <= t) {
			const tm = timers.get(nextId);
			if (tm.every != null) tm.due = t + tm.every; else timers.delete(nextId);
			run(tm.fn, tm.args); return 0;
		}
		if (rafs.size) { const batch = rafs; rafs = new Map(); for (const fn of batch.values()) run(fn, [t]); return 0; }
		return nextId >= 0 ? Math.max(0.01, next - t) : -1;
	};
	G.__mr_hasImmediateWork = () => tasks.length > 0 || rafs.size > 0;

	class MessagePort {
		constructor() { this.onmessage = null; this._other = null; this._l = []; }
		postMessage(data) { const o = this._other; G.setImmediate(() => { const ev = {data, target: o}; o.onmessage?.(ev); for (const l of o._l) l(ev); }); }
		addEventListener(t, l) { if (t === 'message') this._l.push(l); }
		removeEventListener(t, l) { this._l = this._l.filter((x) => x !== l); }
		start() {} close() {}
	}
	G.MessageChannel = class { constructor() { this.port1 = new MessagePort(); this.port2 = new MessagePort(); this.port1._other = this.port2; this.port2._other = this.port1; } };

	G.performance = {now, timeOrigin: Date.now() - now(), mark() {}, measure() {}, clearMarks() {}, clearMeasures() {}, getEntriesByName: () => [], getEntriesByType: () => []};

	// ── small web platform pieces ──────────────────────────────────────────────
	const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
	G.btoa = (s) => { let o = ''; for (let i = 0; i < s.length; i += 3) { const a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2); const n = (a << 16) | ((b || 0) << 8) | (c || 0); o += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + (i + 1 < s.length ? B64[(n >> 6) & 63] : '=') + (i + 2 < s.length ? B64[n & 63] : '='); } return o; };
	G.atob = (s) => { s = String(s).replace(/[^A-Za-z0-9+/]/g, ''); let o = ''; for (let i = 0; i < s.length; i += 4) { const n = (B64.indexOf(s[i]) << 18) | (B64.indexOf(s[i + 1]) << 12) | ((B64.indexOf(s[i + 2]) & 63) << 6) | (B64.indexOf(s[i + 3]) & 63); o += String.fromCharCode((n >> 16) & 255); if (s[i + 2] !== undefined && s[i + 2] !== '=') o += String.fromCharCode((n >> 8) & 255); if (s[i + 3] !== undefined && s[i + 3] !== '=') o += String.fromCharCode(n & 255); } return o; };
	G.TextEncoder = class { get encoding() { return 'utf-8'; } encode(s = '') { const u = unescape(encodeURIComponent(s)); const a = new Uint8Array(u.length); for (let i = 0; i < u.length; i++) a[i] = u.charCodeAt(i); return a; } };
	G.TextDecoder = class { constructor(l = 'utf-8') { this.encoding = l; } decode(b) { if (!b) return ''; const a = b instanceof Uint8Array ? b : new Uint8Array(b.buffer ?? b); let s = ''; for (let i = 0; i < a.length; i += 8192) s += String.fromCharCode.apply(null, a.subarray(i, i + 8192)); try { return decodeURIComponent(escape(s)); } catch { return s; } } };
	G.structuredClone ??= (v) => (v === undefined ? v : JSON.parse(JSON.stringify(v)));
	G.crypto = {getRandomValues: (a) => { for (let i = 0; i < a.length; i++) a[i] = Math.floor(Math.random() * 256 ** (a.BYTES_PER_ELEMENT || 1)); return a; },
		randomUUID: () => 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => { const r = (Math.random() * 16) | 0; return (c === 'x' ? r : (r & 3) | 8).toString(16); })};

	class Event { constructor(type, init = {}) { this.type = type; this.bubbles = !!init.bubbles; this.cancelable = !!init.cancelable; this.defaultPrevented = false; this.target = null; this.currentTarget = null; this.timeStamp = now(); this.detail = init.detail; }
		preventDefault() { this.defaultPrevented = true; } stopPropagation() {} stopImmediatePropagation() {} }
	G.Event = Event; G.CustomEvent = class extends Event {}; G.ErrorEvent = class extends Event { constructor(t, i = {}) { super(t, i); this.error = i.error; this.message = i.message; } };
	class EventTarget {
		addEventListener(t, l) { if (!l) return; (this.__l ??= {}); (this.__l[t] ??= []).push(l); }
		removeEventListener(t, l) { if (this.__l?.[t]) this.__l[t] = this.__l[t].filter((x) => x !== l); }
		dispatchEvent(ev) { ev.target ??= this; ev.currentTarget = this; for (const l of [...(this.__l?.[ev.type] ?? [])]) { try { typeof l === 'function' ? l.call(this, ev) : l.handleEvent(ev); } catch (e) { console.error(e); } } const h = this['on' + ev.type]; if (typeof h === 'function') h.call(this, ev); return !ev.defaultPrevented; }
	}
	G.EventTarget = EventTarget;
	G.AbortSignal = class extends EventTarget { constructor() { super(); this.aborted = false; this.reason = undefined; this.onabort = null; }
		throwIfAborted() { if (this.aborted) throw this.reason; } static timeout() { return new G.AbortSignal(); } static abort(r) { const s = new G.AbortSignal(); s.aborted = true; s.reason = r; return s; } };
	G.AbortController = class { constructor() { this.signal = new G.AbortSignal(); } abort(reason) { if (this.signal.aborted) return; this.signal.aborted = true; this.signal.reason = reason ?? Object.assign(new Error('This operation was aborted'), {name: 'AbortError'}); this.signal.dispatchEvent(new Event('abort')); } };

	// ── URL ────────────────────────────────────────────────────────────────────
	class URLSearchParams {
		constructor(init = '') { this._p = []; if (typeof init === 'string') { for (const kv of init.replace(/^\?/, '').split('&')) { if (!kv) continue; const i = kv.indexOf('='); const d = (x) => decodeURIComponent(x.replace(/\+/g, ' ')); this._p.push(i < 0 ? [d(kv), ''] : [d(kv.slice(0, i)), d(kv.slice(i + 1))]); } } else if (init) { for (const [k, v] of (Symbol.iterator in Object(init) ? init : Object.entries(init))) this._p.push([String(k), String(v)]); } }
		get(k) { const e = this._p.find((p) => p[0] === k); return e ? e[1] : null; } getAll(k) { return this._p.filter((p) => p[0] === k).map((p) => p[1]); }
		has(k) { return this._p.some((p) => p[0] === k); } set(k, v) { this.delete(k); this._p.push([k, String(v)]); } append(k, v) { this._p.push([k, String(v)]); }
		delete(k) { this._p = this._p.filter((p) => p[0] !== k); } forEach(f) { for (const [k, v] of this._p) f(v, k, this); }
		entries() { return this._p[Symbol.iterator](); } keys() { return this._p.map((p) => p[0])[Symbol.iterator](); } values() { return this._p.map((p) => p[1])[Symbol.iterator](); } [Symbol.iterator]() { return this.entries(); }
		get size() { return this._p.length; } toString() { return this._p.map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v)).join('&'); }
	}
	G.URLSearchParams = URLSearchParams;
	const URL_RE = /^([a-zA-Z][a-zA-Z0-9+.-]*:)(?:\/\/(?:([^:@/]*)(?::([^@/]*))?@)?([^:/?#]*)(?::(\d+))?)?([^?#]*)(\?[^#]*)?(#.*)?$/;
	const normPath = (p) => { const out = []; for (const s of p.split('/')) { if (s === '..') { if (out.length > 1) out.pop(); } else if (s !== '.') out.push(s); } let r = out.join('/'); if (!r.startsWith('/')) r = '/' + r; if (/\/\.\.?$/.test(p)) r += '/'; return r; };
	const blobs = new Map(); let blobSeq = 0;
	class URL {
		constructor(u, base) {
			u = String(u);
			let m = URL_RE.exec(u);
			if (!m || (m[4] === undefined && !/^(data|blob|about|javascript|mailto):/i.test(u) && !u.startsWith('file:'))) {
				if (base === undefined) throw new TypeError('Invalid URL: ' + u);
				const b = base instanceof URL ? base : new URL(base);
				if (u.startsWith('//')) return new URL(b.protocol + u);
				let path = b.pathname, search = b.search, hash = '';
				const hi = u.indexOf('#'); if (hi >= 0) { hash = u.slice(hi); u = u.slice(0, hi); }
				const qi = u.indexOf('?'); let rel = u;
				if (qi >= 0) { search = u.slice(qi); rel = u.slice(0, qi); } else if (u !== '') search = '';
				if (rel.startsWith('/')) path = normPath(rel); else if (rel !== '') path = normPath(path.replace(/[^/]*$/, '') + rel);
				m = URL_RE.exec(b.protocol + '//' + b.host + path + search + hash);
			}
			this.protocol = m[1].toLowerCase(); this.username = m[2] ?? ''; this.password = m[3] ?? ''; this.hostname = (m[4] ?? '').toLowerCase(); this.port = m[5] ?? '';
			this.pathname = m[4] !== undefined ? normPath(m[6] || '/') : (m[6] ?? ''); this.search = m[7] && m[7] !== '?' ? m[7] : ''; this.hash = m[8] && m[8] !== '#' ? m[8] : '';
		}
		get host() { return this.hostname + (this.port ? ':' + this.port : ''); }
		get origin() { return this.protocol === 'blob:' ? new URL(this.pathname).origin : this.hostname ? this.protocol + '//' + this.host : 'null'; }
		get href() { return this.protocol + (this.hostname || this.protocol === 'file:' ? '//' + (this.username ? this.username + (this.password ? ':' + this.password : '') + '@' : '') + this.host : '') + this.pathname + this.search + this.hash; }
		set href(v) { Object.assign(this, new URL(v)); }
		get searchParams() { const sp = new URLSearchParams(this.search); const self = this; const sync = () => { const s = sp.toString(); self.search = s ? '?' + s : ''; }; for (const k of ['set', 'append', 'delete']) { const f = sp[k].bind(sp); sp[k] = (...a) => { f(...a); sync(); }; } return sp; }
		toString() { return this.href; } toJSON() { return this.href; }
		static createObjectURL(b) { const u = `blob:${G.location.origin}/${++blobSeq}`; blobs.set(u, b); return u; }
		static revokeObjectURL(u) { blobs.delete(u); }
		static canParse(u, b) { try { new URL(u, b); return true; } catch { return false; } }
	}
	G.URL = URL;
	G.__mrBlobs = blobs;

	class Blob {
		constructor(parts = [], opts = {}) { this.type = opts.type ?? ''; this._parts = parts; this.size = parts.reduce((n, p) => n + (p.byteLength ?? p.size ?? String(p).length), 0); }
		async text() { return this._parts.map((p) => (typeof p === 'string' ? p : new TextDecoder().decode(p))).join(''); }
		async arrayBuffer() { if (this._path) return b64ToBuffer(N.readBase64(this._path)); return new TextEncoder().encode(await this.text()).buffer; }
		slice() { return this; }
	}
	G.Blob = Blob; G.File = class extends Blob { constructor(p, name, o) { super(p, o); this.name = name; } };
	const b64ToBuffer = (b64) => { const s = atob(b64); const a = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) a[i] = s.charCodeAt(i); return a.buffer; };

	// ── location / navigator / misc window props ──────────────────────────────
	const ORIGIN = N.origin(); // e.g. http://localhost:3000
	G.location = Object.assign(new URL(ORIGIN + '/index.html'), {assign() {}, replace() {}, reload() {}});
	G.origin = ORIGIN;
	G.navigator = {userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) MetalReel/0.1', platform: 'MacIntel', language: 'en-US', languages: ['en-US', 'en'], hardwareConcurrency: N.cpuCount(), onLine: true, maxTouchPoints: 0, mediaDevices: undefined, userAgentData: undefined, deviceMemory: 8, gpu: undefined};
	G.devicePixelRatio = 1;
	G.matchMedia = (q) => ({matches: false, media: q, onchange: null, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {}, dispatchEvent() { return true; }});
	G.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
	G.IntersectionObserver = class { constructor(cb) { this.cb = cb; } observe() {} unobserve() {} disconnect() {} takeRecords() { return []; } };
	G.MutationObserver = class { observe() {} disconnect() {} takeRecords() { return []; } };
	G.scrollTo = () => {}; G.scroll = () => {}; G.focus = () => {}; G.blur = () => {}; G.alert = (m) => console.warn('alert: ' + m); G.open = () => null; G.close = () => {};
	G.history = {pushState() {}, replaceState() {}, back() {}, state: null, length: 1};
	G.localStorage = G.sessionStorage = (() => { const m = new Map(); return {getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k), clear: () => m.clear(), key: (i) => [...m.keys()][i] ?? null, get length() { return m.size; }}; })();
	G.process = G.process ?? {env: {NODE_ENV: 'production'}, platform: 'darwin', versions: {}, cwd: () => '/', nextTick: (f, ...a) => queueMicrotask(() => f(...a))};

	// ── DOM ────────────────────────────────────────────────────────────────────
	const UNITLESS = new Set(['animationIterationCount', 'aspectRatio', 'borderImageOutset', 'borderImageSlice', 'borderImageWidth', 'boxFlex', 'boxFlexGroup', 'boxOrdinalGroup', 'columnCount', 'columns', 'flex', 'flexGrow', 'flexPositive', 'flexShrink', 'flexNegative', 'flexOrder', 'gridArea', 'gridRow', 'gridRowEnd', 'gridRowSpan', 'gridRowStart', 'gridColumn', 'gridColumnEnd', 'gridColumnSpan', 'gridColumnStart', 'fontWeight', 'lineClamp', 'lineHeight', 'opacity', 'order', 'orphans', 'scale', 'tabSize', 'widows', 'zIndex', 'zoom', 'fillOpacity', 'floodOpacity', 'stopOpacity', 'strokeDasharray', 'strokeDashoffset', 'strokeMiterlimit', 'strokeOpacity', 'strokeWidth', 'WebkitLineClamp', 'MozAnimationIterationCount']);
	const camel = (k) => (k.startsWith('--') ? k : k.replace(/^-ms-/, 'ms-').replace(/-([a-z])/g, (_, c) => c.toUpperCase()));
	const kebab = (k) => (k.startsWith('--') ? k : k.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase()).replace(/^(webkit|moz|ms)-/, '-$1-'));
	const styleValue = (k, v) => (v == null || typeof v === 'boolean' || v === '' ? '' : typeof v === 'number' && v !== 0 && !UNITLESS.has(k) && !k.startsWith('--') ? v + 'px' : String(v).trim());
	function makeStyle(el) {
		const data = Object.create(null);
		const api = {
			setProperty(k, v, prio) { const c = camel(k); const s = styleValue(c, v); if (s === '') delete data[c]; else data[c] = prio === 'important' ? s + ' !important' : s; el.__dirty(); },
			removeProperty(k) { const c = camel(k); const old = data[c]; delete data[c]; el.__dirty(); return old ?? ''; },
			getPropertyValue(k) { return (data[camel(k)] ?? '').replace(/ !important$/, ''); },
			getPropertyPriority(k) { return /!important$/.test(data[camel(k)] ?? '') ? 'important' : ''; },
			item(i) { return kebab(Object.keys(data)[i] ?? ''); },
			get length() { return Object.keys(data).length; },
			get cssText() { return Object.entries(data).map(([k, v]) => kebab(k) + ': ' + v).join('; '); },
			set cssText(t) { for (const k in data) delete data[k]; for (const d of String(t).split(';')) { const i = d.indexOf(':'); if (i > 0) data[camel(d.slice(0, i).trim())] = d.slice(i + 1).trim(); } el.__dirty(); },
			__data: data,
		};
		return new Proxy(api, {
			get(t, k) { if (k in t) return t[k]; if (typeof k !== 'string') return undefined; return (data[k] ?? '').replace(/ !important$/, ''); },
			set(t, k, v) { if (k in t && k !== 'cssText') return true; if (k === 'cssText') { t.cssText = v; return true; } if (typeof k === 'string') { const s = styleValue(k, v); if (s === '') delete data[k]; else if (!/!important$/.test(data[k] ?? '') || k !== 'display') data[k] = s; el.__dirty(); } return true; },
			has(t, k) { return k in t || k in data; }, ownKeys() { return Object.keys(data); }, getOwnPropertyDescriptor(t, k) { return k in data ? {value: data[k], enumerable: true, configurable: true, writable: true} : undefined; },
		});
	}

	let dirty = true;
	class Node extends EventTarget {
		constructor(type, name) { super(); this.nodeType = type; this.nodeName = name; this.parentNode = null; this.childNodes = []; this.ownerDocument = G.document ?? null; }
		__dirty() { dirty = true; }
		get parentElement() { return this.parentNode && this.parentNode.nodeType === 1 ? this.parentNode : null; }
		get firstChild() { return this.childNodes[0] ?? null; } get lastChild() { return this.childNodes[this.childNodes.length - 1] ?? null; }
		get nextSibling() { const p = this.parentNode; if (!p) return null; return p.childNodes[p.childNodes.indexOf(this) + 1] ?? null; }
		get previousSibling() { const p = this.parentNode; if (!p) return null; return p.childNodes[p.childNodes.indexOf(this) - 1] ?? null; }
		get isConnected() { let n = this; while (n.parentNode) n = n.parentNode; return n === G.document; }
		hasChildNodes() { return this.childNodes.length > 0; }
		contains(o) { for (let n = o; n; n = n.parentNode) if (n === this) return true; return false; }
		_adopt(c) { if (c.nodeType === 11) return [...c.childNodes].map((x) => { c.removeChild(x); return x; }); if (c.parentNode) c.parentNode.removeChild(c); return [c]; }
		appendChild(c) { for (const x of this._adopt(c)) { x.parentNode = this; this.childNodes.push(x); this._inserted(x); } dirty = true; return c; }
		insertBefore(c, ref) { if (!ref) return this.appendChild(c); for (const x of this._adopt(c)) { const i = this.childNodes.indexOf(ref); x.parentNode = this; this.childNodes.splice(i < 0 ? this.childNodes.length : i, 0, x); this._inserted(x); } dirty = true; return c; }
		removeChild(c) { const i = this.childNodes.indexOf(c); if (i >= 0) this.childNodes.splice(i, 1); c.parentNode = null; dirty = true; return c; }
		replaceChild(n, o) { this.insertBefore(n, o); return this.removeChild(o); }
		remove() { this.parentNode?.removeChild(this); }
		append(...ns) { for (const n of ns) this.appendChild(typeof n === 'string' ? G.document.createTextNode(n) : n); }
		prepend(...ns) { const f = this.firstChild; for (const n of ns) this.insertBefore(typeof n === 'string' ? G.document.createTextNode(n) : n, f); }
		_inserted(x) { if (x.nodeType === 1) x._connected?.(); }
		cloneNode(deep) { const c = this.nodeType === 3 ? G.document.createTextNode(this.nodeValue) : G.document.createElementNS(this.namespaceURI, this.localName); if (this.nodeType === 1) { for (const [k, v] of this.__attrs) c.__attrs.set(k, v); c.style.cssText = this.style.cssText; } if (deep) for (const ch of this.childNodes) c.appendChild(ch.cloneNode(true)); return c; }
		get textContent() { return this.nodeType === 3 ? this.nodeValue : this.childNodes.map((c) => c.textContent).join(''); }
		set textContent(t) { if (this.nodeType === 3) { this.nodeValue = String(t); dirty = true; return; } for (const c of [...this.childNodes]) this.removeChild(c); if (t !== '' && t != null) this.appendChild(G.document.createTextNode(String(t))); }
	}
	class Text extends Node { constructor(t) { super(3, '#text'); this._v = String(t); } get nodeValue() { return this._v; } set nodeValue(v) { this._v = String(v); dirty = true; } get data() { return this._v; } set data(v) { this.nodeValue = v; } get wholeText() { return this._v; } }
	class Comment extends Node { constructor(t) { super(8, '#comment'); this.nodeValue = t; } get textContent() { return ''; } }
	class DocumentFragment extends Node { constructor() { super(11, '#document-fragment'); } }
	const HTML_NS = 'http://www.w3.org/1999/xhtml', SVG = 'http://www.w3.org/2000/svg';
	const ATTR_PROPS = {id: 'id', className: 'class', htmlFor: 'for', src: 'src', href: 'href', alt: 'alt', title: 'title', type: 'type', name: 'name', rel: 'rel', crossOrigin: 'crossorigin', width: 'width', height: 'height', dir: 'dir', lang: 'lang', role: 'role', tabIndex: 'tabindex', charset: 'charset', media: 'media', poster: 'poster', decoding: 'decoding', loading: 'loading'};
	class Element extends Node {
		constructor(ns, local) {
			const tag = ns === HTML_NS ? local.toUpperCase() : local;
			super(1, tag); this.namespaceURI = ns; this.localName = ns === HTML_NS ? local.toLowerCase() : local; this.tagName = tag; this.__attrs = new Map(); this.style = makeStyle(this); this.__props = null;
		}
		get children() { return this.childNodes.filter((c) => c.nodeType === 1); } get childElementCount() { return this.children.length; }
		get firstElementChild() { return this.children[0] ?? null; } get lastElementChild() { const c = this.children; return c[c.length - 1] ?? null; }
		get nextElementSibling() { let n = this.nextSibling; while (n && n.nodeType !== 1) n = n.nextSibling; return n; }
		get previousElementSibling() { let n = this.previousSibling; while (n && n.nodeType !== 1) n = n.previousSibling; return n; }
		getAttribute(k) { return this.__attrs.has(k) ? this.__attrs.get(k) : k === 'style' ? this.style.cssText || null : null; }
		setAttribute(k, v) { if (k === 'style') { this.style.cssText = v; return; } this.__attrs.set(k, String(v)); dirty = true; if (k === 'src') this._srcChanged?.(); }
		setAttributeNS(_ns, k, v) { this.setAttribute(k, v); } getAttributeNS(_ns, k) { return this.getAttribute(k); } removeAttributeNS(_ns, k) { this.removeAttribute(k); }
		removeAttribute(k) { this.__attrs.delete(k); dirty = true; } hasAttribute(k) { return this.__attrs.has(k); } toggleAttribute(k, f) { if (f ?? !this.hasAttribute(k)) this.setAttribute(k, ''); else this.removeAttribute(k); }
		get attributes() { return [...this.__attrs].map(([name, value]) => ({name, value})); }
		get classList() { const el = this; const get = () => (el.getAttribute('class') ?? '').split(/\s+/).filter(Boolean); const set = (a) => el.setAttribute('class', a.join(' '));
			return {add: (...c) => set([...new Set([...get(), ...c])]), remove: (...c) => set(get().filter((x) => !c.includes(x))), contains: (c) => get().includes(c), toggle: (c, f) => { const has = get().includes(c); if (f ?? !has) set([...new Set([...get(), c])]); else set(get().filter((x) => x !== c)); return f ?? !has; }, get length() { return get().length; }, item: (i) => get()[i] ?? null, toString: () => get().join(' ')}; }
		get dataset() { const el = this; return new Proxy({}, {get: (_, k) => el.getAttribute('data-' + kebab(String(k))) ?? undefined, set: (_, k, v) => { el.setAttribute('data-' + kebab(String(k)), v); return true; }}); }
		getBoundingClientRect() { const l = this.__layout ?? [0, 0, 0, 0]; return {x: l[0], y: l[1], left: l[0], top: l[1], width: l[2], height: l[3], right: l[0] + l[2], bottom: l[1] + l[3], toJSON() { return this; }}; }
		getClientRects() { return [this.getBoundingClientRect()]; }
		get offsetWidth() { return this.__layout?.[2] ?? 0; } get offsetHeight() { return this.__layout?.[3] ?? 0; } get clientWidth() { return this.offsetWidth; } get clientHeight() { return this.offsetHeight; }
		get offsetLeft() { return this.__layout?.[0] ?? 0; } get offsetTop() { return this.__layout?.[1] ?? 0; } get scrollWidth() { return this.offsetWidth; } get scrollHeight() { return this.offsetHeight; }
		scrollTop = 0; scrollLeft = 0; scrollIntoView() {} focus() {} blur() {} click() {}
		matches(sel) { return matchSimple(this, sel); } closest(sel) { for (let n = this; n && n.nodeType === 1; n = n.parentNode) if (matchSimple(n, sel)) return n; return null; }
		querySelector(sel) { return queryAll(this, sel)[0] ?? null; } querySelectorAll(sel) { return queryAll(this, sel); }
		getElementsByTagName(t) { return queryAll(this, t); } getElementsByClassName(c) { return queryAll(this, '.' + c); }
		get innerHTML() { return this.childNodes.map(serialize).join(''); }
		set innerHTML(h) { for (const c of [...this.childNodes]) this.removeChild(c); this.__html = String(h); dirty = true; }
		get outerHTML() { return serialize(this); }
		get innerText() { return this.textContent; } set innerText(t) { this.textContent = t; }
		animate() { return {cancel() {}, finish() {}, play() {}, pause() {}, finished: Promise.resolve(), onfinish: null}; }
		attachShadow() { return this; }
		getAnimations() { return []; }
	}
	for (const [p, a] of Object.entries(ATTR_PROPS)) Object.defineProperty(Element.prototype, p, {get() { const v = this.getAttribute(a); return v ?? ''; }, set(v) { this.setAttribute(a, v); }, configurable: true});
	Object.defineProperty(Element.prototype, 'src', {get() { const v = this.getAttribute('src'); return v == null ? '' : v.startsWith('blob:') || v.startsWith('data:') ? v : new URL(v, G.location.href).href; }, set(v) { this.setAttribute('src', v); }, configurable: true});

	class HTMLImageElement extends Element {
		constructor() { super(HTML_NS, 'img'); }
		get complete() { return true; }
		get naturalWidth() { return this._size()[0]; } get naturalHeight() { return this._size()[1]; }
		_size() { const s = this.getAttribute('src'); if (!s) return [0, 0]; if (this._sz && this._szFor === s) return this._sz; const b = blobs.get(s); this._szFor = s; this._sz = b?.__video ? [1920, 1080] : (N.imageSize(resolveLocal(s)) ?? [1, 1]); return this._sz; }
		decode() { return Promise.resolve(); }
		_srcChanged() { const el = this; G.setImmediate(() => el.dispatchEvent(new Event('load'))); }
	}
	class HTMLScriptElement extends Element {
		constructor() { super(HTML_NS, 'script'); }
		_connected() {
			if (this.__ran) return; this.__ran = true;
			const src = this.getAttribute('src'); const el = this;
			if (src) G.setImmediate(() => { const p = resolveLocal(new URL(src, G.location.href).href); const ok = p && N.evalFile(p, src); el.dispatchEvent(new Event(ok ? 'load' : 'error')); });
			else if (this.textContent) N.evalScript(this.textContent, 'inline-script');
		}
	}
	class HTMLCanvasElement extends Element {
		constructor() { super(HTML_NS, 'canvas'); }
		getContext(kind) { if (!this.__warned) { this.__warned = true; console.warn(`[metalreel] <canvas>.getContext('${kind}') is not available in native mode; use --mode hybrid for this composition`); } G.__mr_unsupported?.add('canvas ' + kind); return null; }
		toDataURL() { return 'data:,'; } toBlob(cb) { cb(null); }
		get width() { return +(this.getAttribute('width') ?? 300); } set width(v) { this.setAttribute('width', v); }
		get height() { return +(this.getAttribute('height') ?? 150); } set height(v) { this.setAttribute('height', v); }
	}
	class HTMLMediaElement extends Element { constructor(t) { super(HTML_NS, t); this.currentTime = 0; this.duration = NaN; this.paused = true; this.muted = false; this.volume = 1; this.playbackRate = 1; this.readyState = 4; this.videoWidth = 0; this.videoHeight = 0; } play() { return Promise.resolve(); } pause() {} load() {} canPlayType() { return 'probably'; } requestVideoFrameCallback() { return 0; } cancelVideoFrameCallback() {} }
	G.Node = Node; G.Element = Element; G.HTMLElement = Element; G.SVGElement = Element; G.Text = Text; G.Comment = Comment; G.DocumentFragment = DocumentFragment;
	G.HTMLImageElement = HTMLImageElement; G.HTMLCanvasElement = HTMLCanvasElement; G.HTMLVideoElement = HTMLMediaElement; G.HTMLAudioElement = HTMLMediaElement; G.HTMLMediaElement = HTMLMediaElement; G.HTMLScriptElement = HTMLScriptElement;
	G.HTMLDivElement = G.HTMLSpanElement = G.HTMLStyleElement = G.HTMLLinkElement = G.HTMLInputElement = G.HTMLIFrameElement = Element; G.SVGSVGElement = G.SVGPathElement = Element;
	G.Image = function Image(w, h) { const i = new HTMLImageElement(); if (w) i.setAttribute('width', w); if (h) i.setAttribute('height', h); return i; };
	G.Audio = function Audio(src) { const a = new HTMLMediaElement('audio'); if (src) a.setAttribute('src', src); return a; };

	// minimal selectors: tag, #id, .class, [attr], [attr=value], compound of those, comma lists, descendant (space)
	function matchSimple(el, sel) {
		return String(sel).split(',').some((s) => {
			const parts = s.trim().split(/\s+/); let n = el;
			if (!matchCompound(n, parts[parts.length - 1])) return false;
			for (let i = parts.length - 2; i >= 0; i--) { n = n.parentNode; while (n && n.nodeType === 1 && !matchCompound(n, parts[i])) n = n.parentNode; if (!n || n.nodeType !== 1) return false; }
			return true;
		});
	}
	function matchCompound(el, c) {
		if (el.nodeType !== 1) return false;
		const re = /([#.]?[-\w]+|\*|\[[^\]]+\])/g; let m, any = false;
		while ((m = re.exec(c))) { any = true; const t = m[1];
			if (t === '*') continue;
			if (t[0] === '#') { if (el.getAttribute('id') !== t.slice(1)) return false; }
			else if (t[0] === '.') { if (!(el.getAttribute('class') ?? '').split(/\s+/).includes(t.slice(1))) return false; }
			else if (t[0] === '[') { const mm = /^\[\s*([-\w:]+)\s*(?:([~^$*|]?=)\s*["']?([^"'\]]*)["']?)?\s*\]$/.exec(t); if (!mm) return false; const v = el.getAttribute(mm[1]); if (v == null) return false; if (mm[2] === '=' && v !== mm[3]) return false; }
			else if (el.localName.toLowerCase() !== t.toLowerCase()) return false; }
		return any;
	}
	function queryAll(root, sel) { const out = []; const walk = (n) => { for (const c of n.childNodes) { if (c.nodeType === 1) { if (matchSimple(c, sel)) out.push(c); walk(c); } } }; walk(root); return out; }

	const VOID = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr']);
	const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
	const escA = (s) => esc(s).replace(/"/g, '&quot;');
	function serialize(n) {
		if (n.nodeType === 3) return n.__hidden ? '' : esc(n.nodeValue);
		if (n.nodeType !== 1) return '';
		let s = '<' + n.localName;
		if (n.localName === 'svg' && !n.__attrs.has('xmlns')) s += ' xmlns="http://www.w3.org/2000/svg"';
		for (const [k, v] of n.__attrs) s += ` ${k}="${escA(k === 'href' || k === 'xlink:href' ? absolutize(v) : v)}"`;
		const css = n.style.cssText; if (css) s += ` style="${escA(css)}"`;
		if (VOID.has(n.localName) && n.namespaceURI === HTML_NS) return s + '>';
		return s + '>' + (n.__html ?? n.childNodes.map(serialize).join('')) + '</' + n.localName + '>';
	}
	const absolutize = (v) => { if (!v || v.startsWith('#') || v.startsWith('data:')) return v; try { const p = resolveLocal(new URL(v, G.location.href).href); return p ? 'file://' + p : v; } catch { return v; } };

	class Document extends Node {
		constructor() { super(9, '#document'); }
		createElement(t) { t = String(t).toLowerCase(); return t === 'img' ? new HTMLImageElement() : t === 'script' ? new HTMLScriptElement() : t === 'canvas' ? new HTMLCanvasElement() : t === 'video' || t === 'audio' ? new HTMLMediaElement(t) : new Element(HTML_NS, t); }
		createElementNS(ns, t) { return ns === HTML_NS || !ns ? this.createElement(t) : new Element(ns, t); }
		createTextNode(t) { return new Text(t); } createComment(t) { return new Comment(t); } createDocumentFragment() { return new DocumentFragment(); }
		createEvent() { return new Event(''); } createRange() { return {setStart() {}, setEnd() {}, getBoundingClientRect: () => ({x: 0, y: 0, width: 0, height: 0}), selectNodeContents() {}, collapse() {}}; }
		getElementById(id) { return queryAll(this, '#' + id)[0] ?? null; }
		querySelector(s) { return queryAll(this, s)[0] ?? null; } querySelectorAll(s) { return queryAll(this, s); }
		getElementsByTagName(t) { return queryAll(this, t); } getElementsByClassName(c) { return queryAll(this, '.' + c); }
		get head() { return this._head; } get body() { return this._body; } get documentElement() { return this._html; }
		get readyState() { return 'complete'; } get visibilityState() { return 'visible'; } get hidden() { return false; }
		get baseURI() { return G.location.href; } get URL() { return G.location.href; } get location() { return G.location; }
		get styleSheets() { return []; } get activeElement() { return this._body; } hasFocus() { return true; }
		get defaultView() { return G; } cookie = ''; title = ''; currentScript = null;
	}
	const document = new Document();
	G.document = document;
	document._html = new Element(HTML_NS, 'html'); document._head = new Element(HTML_NS, 'head'); document._body = new Element(HTML_NS, 'body');
	document.childNodes.push(document._html); document._html.parentNode = document;
	document._html.appendChild(document._head); document._html.appendChild(document._body);
	for (const n of [document._html, document._head, document._body]) n.ownerDocument = document;
	G.getComputedStyle = (el) => el.style;

	// ── fetch ──────────────────────────────────────────────────────────────────
	/** URL → local file path (bundle dir, public dir, file://, or downloaded remote file in the cache). */
	function resolveLocal(u) { if (u.startsWith('/')) u = ORIGIN + u; return N.resolve(u); }
	G.__mr_resolveLocal = resolveLocal;
	class Headers { constructor(h = {}) { this._h = new Map(Object.entries(h).map(([k, v]) => [k.toLowerCase(), String(v)])); } get(k) { return this._h.get(k.toLowerCase()) ?? null; } has(k) { return this._h.has(k.toLowerCase()); } set(k, v) { this._h.set(k.toLowerCase(), String(v)); } append(k, v) { this.set(k, v); } forEach(f) { for (const [k, v] of this._h) f(v, k, this); } entries() { return this._h.entries(); } [Symbol.iterator]() { return this._h.entries(); } }
	G.Headers = Headers;
	class Response {
		constructor(body = null, init = {}) { this.status = init.status ?? 200; this.statusText = init.statusText ?? ''; this.ok = this.status >= 200 && this.status < 300; this.headers = new Headers(init.headers ?? {}); this.url = init.url ?? ''; this._path = init._path ?? null; this._body = body; this._blob = init._blob ?? null; this.bodyUsed = false; this.type = 'basic'; this.redirected = false; }
		async text() { if (this._path) return N.readText(this._path) ?? ''; if (this._body instanceof Blob) return this._body.text(); return this._body == null ? '' : typeof this._body === 'string' ? this._body : new TextDecoder().decode(this._body); }
		async json() { return JSON.parse(await this.text()); }
		async arrayBuffer() { if (this._path) return b64ToBuffer(N.readBase64(this._path)); if (typeof this._body === 'string') return new TextEncoder().encode(this._body).buffer; return this._body?.buffer ?? this._body ?? new ArrayBuffer(0); }
		async blob() { if (this._blob) return this._blob; const b = new Blob([], {type: this.headers.get('content-type') ?? ''}); b._path = this._path; b.__src = this.url; return b; }
		async bytes() { return new Uint8Array(await this.arrayBuffer()); }
		clone() { return new Response(this._body, {status: this.status, headers: Object.fromEntries(this.headers._h), url: this.url, _path: this._path, _blob: this._blob}); }
		get body() { return null; }
	}
	G.Response = Response; G.Request = class { constructor(u, o = {}) { this.url = String(u?.url ?? u); this.method = o.method ?? 'GET'; this.headers = new Headers(o.headers); this.signal = o.signal; } };
	G.fetch = (input, opts = {}) => new Promise((resolve, reject) => {
		const url = new URL(String(input?.url ?? input), G.location.href).href;
		if (opts.signal?.aborted) return reject(Object.assign(new Error('The operation was aborted.'), {name: 'AbortError'}));
		// <OffthreadVideo> asks Remotion's frame server for a decoded frame. We never decode in JS:
		// the response is a marker blob; Swift decodes the frame on the GPU when it paints the <img>.
		const pu = new URL(url);
		if (pu.pathname === '/proxy' && pu.searchParams.get('src')) {
			const b = new Blob([], {type: 'image/png'}); b.__video = {src: pu.searchParams.get('src'), time: +pu.searchParams.get('time'), transparent: pu.searchParams.get('transparent') === 'true', toneMapped: pu.searchParams.get('toneMapped') !== 'false'};
			return resolve(new Response(null, {status: 200, url, _blob: b, headers: {'content-type': 'image/png'}}));
		}
		if (url.startsWith('blob:')) { const b = blobs.get(url); return b ? resolve(new Response(b, {url, _blob: b})) : resolve(new Response(null, {status: 404, url})); }
		if (url.startsWith('data:')) { const m = /^data:([^,;]*)(;base64)?,(.*)$/s.exec(url); const s = m[2] ? atob(m[3]) : decodeURIComponent(m[3]); const a = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) a[i] = s.charCodeAt(i); return resolve(new Response(a, {url, headers: {'content-type': m[1]}})); }
		const r = N.fetch(url, opts.method ?? 'GET'); // {status, path, type}
		if (!r || r.status === 0) return reject(new TypeError('Failed to fetch ' + url));
		resolve(new Response(null, {status: r.status, url, _path: r.path, headers: {'content-type': r.type ?? ''}}));
	});
	G.XMLHttpRequest = class extends EventTarget { open(m, u) { this._u = u; } send() { G.fetch(this._u).then(async (r) => { this.status = r.status; this.responseText = await r.text(); this.response = this.responseText; this.readyState = 4; this.dispatchEvent(new Event('load')); this.onreadystatechange?.(); }, () => this.dispatchEvent(new Event('error'))); } setRequestHeader() {} getResponseHeader() { return null; } abort() {} };

	// ── fonts ──────────────────────────────────────────────────────────────────
	const fontSet = new Set();
	class FontFace {
		constructor(family, source, desc = {}) { this.family = String(family).replace(/^["']|["']$/g, ''); this._src = source; this.weight = String(desc.weight ?? 'normal'); this.style = String(desc.style ?? 'normal'); this.unicodeRange = String(desc.unicodeRange ?? 'U+0-10FFFF'); this.display = desc.display ?? 'auto'; this.stretch = desc.stretch ?? 'normal'; this.status = 'unloaded'; this._p = null; this.loaded = new Promise((r, j) => { this._res = r; this._rej = j; }); this.loaded.catch(() => {}); }
		load() {
			if (this._p) return this._p;
			this.status = 'loading';
			this._p = (async () => {
				let path = null;
				if (typeof this._src === 'string') {
					const urls = [...this._src.matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/g)].map((m) => m[1]);
					for (const u of urls) { const r = N.fetch(new URL(u, G.location.href).href, 'GET'); if (r && r.status === 200) { path = r.path; break; } }
				} else if (this._src) {
					const u8 = new Uint8Array(this._src.buffer ?? this._src); let t = ''; for (let i = 0; i < u8.length; i += 8192) t += String.fromCharCode.apply(null, u8.subarray(i, i + 8192));
					path = N.writeTemp(btoa(t), '.font');
				}
				if (!path) { this.status = 'error'; const e = new Error('Failed to load font ' + this.family); this._rej(e); throw e; }
				this._path = path; this.status = 'loaded'; this._res(this); return this;
			})();
			return this._p;
		}
	}
	G.FontFace = FontFace;
	const register = (ff) => { if (ff._registered || !ff._path) return; ff._registered = true; N.registerFont(ff.family, ff._path, ff.weight, ff.style, ff.unicodeRange === 'U+0-10FFFF' ? '' : ff.unicodeRange); };
	document.fonts = Object.assign(new EventTarget(), {
		add(ff) { fontSet.add(ff); if (ff.status === 'loaded') register(ff); else ff.load().then(() => register(ff), () => {}); return this; },
		delete(ff) { return fontSet.delete(ff); }, has(ff) { return fontSet.has(ff); }, clear() { fontSet.clear(); },
		check: () => true, load: async () => [...fontSet], forEach(f) { fontSet.forEach((x) => f(x, x, this)); },
		get size() { return fontSet.size; }, get status() { return 'loaded'; }, [Symbol.iterator]() { return fontSet.values(); }, values() { return fontSet.values(); }, entries() { return [...fontSet].map((x) => [x, x])[Symbol.iterator](); },
		get ready() { return Promise.all([...fontSet].map((f) => f.loaded.catch(() => {}))).then(() => document.fonts); },
		onloadingdone: null,
	});
	G.FontFaceSet = Object; // existence check only

	// ── React prop → DOM (used by our react-dom host config) ───────────────────
	const SVG_KEEP_CAMEL = new Set(['viewBox', 'preserveAspectRatio', 'gradientUnits', 'gradientTransform', 'patternUnits', 'patternContentUnits', 'patternTransform', 'stdDeviation', 'baseFrequency', 'numOctaves', 'filterUnits', 'primitiveUnits', 'pathLength', 'markerWidth', 'markerHeight', 'markerUnits', 'refX', 'refY', 'maskUnits', 'maskContentUnits', 'clipPathUnits', 'spreadMethod', 'startOffset', 'textLength', 'lengthAdjust', 'tableValues', 'kernelMatrix', 'surfaceScale', 'specularExponent', 'diffuseConstant', 'kernelUnitLength', 'limitingConeAngle', 'pointsAtX', 'pointsAtY', 'pointsAtZ', 'specularConstant', 'stitchTiles', 'xChannelSelector', 'yChannelSelector', 'edgeMode', 'targetX', 'targetY', 'attributeName', 'repeatCount', 'keyTimes', 'keySplines', 'calcMode']);
	const svgAttr = (k) => (k === 'xlinkHref' ? 'xlink:href' : k === 'xmlnsXlink' ? 'xmlns:xlink' : k === 'xmlSpace' ? 'xml:space' : SVG_KEEP_CAMEL.has(k) ? k : k.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase()));
	const SKIP = new Set(['children', 'key', 'ref', 'dangerouslySetInnerHTML', 'suppressContentEditableWarning', 'suppressHydrationWarning', 'defaultValue', 'defaultChecked', 'innerHTML']);
	function applyProps(el, oldP, newP) {
		const isSvg = el.namespaceURI === SVG;
		if (oldP) for (const k in oldP) if (!(k in newP) && !SKIP.has(k)) {
			if (k === 'style') { el.style.cssText = ''; continue; }
			if (/^on[A-Z]/.test(k)) { el.removeEventListener(k.slice(2).toLowerCase(), oldP[k]); continue; }
			el.removeAttribute(k === 'className' ? 'class' : isSvg ? svgAttr(k) : (ATTR_PROPS[k] ?? k.toLowerCase()));
		}
		for (const k in newP) {
			const v = newP[k];
			if (SKIP.has(k)) {
				if (k === 'dangerouslySetInnerHTML') el.innerHTML = v?.__html ?? '';
				else if (k === 'children' && (typeof v === 'string' || typeof v === 'number' || typeof v === 'bigint')) { if (!oldP || oldP.children !== v) el.textContent = String(v); }
				continue;
			}
			if (oldP && oldP[k] === v && k !== 'style') continue;
			if (k === 'style') {
				const o = oldP?.style ?? {}, n = v ?? {};
				for (const s in o) if (!(s in n)) el.style[s] = '';
				for (const s in n) if (o[s] !== n[s] || !oldP) { if (s.startsWith('--')) el.style.setProperty(s, n[s]); else el.style[s] = n[s]; }
				continue;
			}
			if (/^on[A-Z]/.test(k)) { const t = k.slice(2).toLowerCase().replace(/capture$/, ''); if (oldP?.[k]) el.removeEventListener(t, oldP[k]); if (typeof v === 'function') el.addEventListener(t, v); continue; }
			const a = k === 'className' ? 'class' : isSvg ? svgAttr(k) : (ATTR_PROPS[k] ?? (k.startsWith('data-') || k.startsWith('aria-') ? k : k.toLowerCase()));
			if (v == null || v === false || typeof v === 'function' || typeof v === 'symbol') el.removeAttribute(a);
			else el.setAttribute(a, v === true ? '' : v);
		}
	}

	// ── per-frame snapshot for Swift ───────────────────────────────────────────
	// Compact JSON: element = {t, s?, a?, c?, h?}; text = string.
	//   t: tag (lowercase), s: style (camelCase → CSS string), a: selected attributes,
	//   h: serialized markup for subtrees we can't paint natively (svg, raw HTML) → WebKit fallback.
	const KEEP_ATTRS = ['class', 'id', 'width', 'height', 'viewBox'];
	G.__mr_unsupported = new Set();
	function snap(n, inSvg) {
		if (n.nodeType === 3) return n.__hidden || n._v === '' ? null : n._v;
		if (n.nodeType !== 1) return null;
		const t = n.localName.toLowerCase();
		if (t === 'script' || t === 'style' || t === 'link' || t === 'meta' || t === 'template' || t === 'noscript') return null;
		const o = {t};
		const st = n.style.__data; let hasS = false; for (const _ in st) { hasS = true; break; } if (hasS) o.s = st;
		let a = null;
		for (const k of KEEP_ATTRS) { const v = n.__attrs.get(k); if (v != null) (a ??= {})[k] = v; }
		if (t === 'img' || t === 'video') {
			const raw = n.__attrs.get('src');
			if (raw) { const b = blobs.get(raw); (a ??= {}); if (b?.__video) { a.video = b.__video.src.startsWith('http') || b.__video.src.startsWith('/') ? resolveLocal(b.__video.src) : b.__video.src; a.time = b.__video.time; a.toneMapped = b.__video.toneMapped; } else if (b?._path) a.src = b._path; else a.src = resolveLocal(new URL(raw, G.location.href).href); }
		}
		if (a) o.a = a;
		if (t === 'svg' || n.__html != null || t === 'iframe' || t === 'canvas' || t === 'math') {
			if (t === 'canvas') G.__mr_unsupported.add('canvas');
			o.h = serialize(n);
			return o;
		}
		if (n.childNodes.length) { const c = []; for (const ch of n.childNodes) { const s = snap(ch); if (s != null) c.push(s); } if (c.length) o.c = c; }
		return o;
	}
	G.__mr_snapshot = (rootSel) => { const root = rootSel ? document.querySelector(rootSel) : document.body; dirty = false; return JSON.stringify(root ? snap(root) : null); };
	G.__mr_isDirty = () => dirty;
	G.__mrDOM = {document, applyProps, markDirty: () => { dirty = true; }, serialize, resolveLocal};
})();
