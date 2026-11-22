// MetalReel's replacement for `react-dom` / `react-dom/client`.
//
// The Remotion bundle is built with Remotion's own bundler; the only change is a webpack alias that
// points `react-dom` and `react-dom/client` here. Everything else (remotion, @remotion/*, user code)
// runs unmodified inside JavaScriptCore.
//
// Host instances are the lightweight DOM nodes from prelude.js (`globalThis.__mrDOM`), so imperative
// code that Remotion and user components run against refs (`el.style.x = …`, `img.src = …`,
// `appendChild`, portals into `document.createElement('div')`) keeps working. Swift reads the tree
// once per frame through `__mr_snapshot()` (see prelude.js) and does layout, text and painting natively.
import Reconciler from 'react-reconciler';
import {DefaultEventPriority, DiscreteEventPriority, ConcurrentRoot, LegacyRoot} from 'react-reconciler/constants';
import * as React from 'react';

const DOM = () => globalThis.__mrDOM;
const SVG_NS = 'http://www.w3.org/2000/svg';

let currentUpdatePriority = 0;

const hostConfig = {
	rendererPackageName: 'metalreel-react-dom',
	rendererVersion: React.version,
	extraDevToolsConfig: null,
	isPrimaryRenderer: true,
	warnsIfNotActing: false,
	supportsMutation: true,
	supportsPersistence: false,
	supportsHydration: false,
	supportsResources: false,
	supportsSingletons: false,
	supportsTestSelectors: false,
	supportsMicrotasks: true,
	scheduleMicrotask: (fn) => queueMicrotask(fn),
	scheduleTimeout: (fn, ms) => setTimeout(fn, ms),
	cancelTimeout: (id) => clearTimeout(id),
	noTimeout: -1,
	NotPendingTransition: null,
	HostTransitionContext: React.createContext(null),

	getRootHostContext: () => ({svg: false}),
	getChildHostContext: (parent, type) => {
		const svg = type === 'svg' ? true : type === 'foreignObject' ? false : parent.svg;
		return svg === parent.svg ? parent : {svg};
	},
	getPublicInstance: (i) => i,
	prepareForCommit: () => null,
	resetAfterCommit: (container) => { DOM().markDirty(container); },
	preparePortalMount: () => {},

	createInstance(type, props, _root, ctx) {
		const el = ctx.svg || type === 'svg' ? DOM().document.createElementNS(SVG_NS, type) : DOM().document.createElement(type);
		DOM().applyProps(el, null, props);
		return el;
	},
	createTextInstance: (text) => DOM().document.createTextNode(text),
	appendInitialChild: (p, c) => p.appendChild(c),
	finalizeInitialChildren: (el, type, props) => !!props.autoFocus && false,
	shouldSetTextContent: (type, props) => type === 'textarea' || type === 'noscript' ||
		typeof props.children === 'string' || typeof props.children === 'number' || typeof props.children === 'bigint' ||
		(props.dangerouslySetInnerHTML != null && props.dangerouslySetInnerHTML.__html != null),
	resetTextContent: (el) => { el.textContent = ''; },

	appendChild: (p, c) => p.appendChild(c),
	appendChildToContainer: (container, c) => container.appendChild(c),
	insertBefore: (p, c, before) => p.insertBefore(c, before),
	insertInContainerBefore: (container, c, before) => container.insertBefore(c, before),
	removeChild: (p, c) => p.removeChild(c),
	removeChildFromContainer: (container, c) => container.removeChild(c),
	clearContainer: (container) => { while (container.firstChild) container.removeChild(container.firstChild); },
	commitTextUpdate: (t, _old, text) => { t.nodeValue = text; },
	commitMount: () => {},
	commitUpdate: (el, type, oldProps, newProps) => DOM().applyProps(el, oldProps, newProps),
	hideInstance: (el) => { el.style.setProperty('display', 'none', 'important'); },
	unhideInstance: (el, props) => { el.style.removeProperty('display'); if (props.style && props.style.display != null) el.style.display = props.style.display; },
	hideTextInstance: (t) => { t.__hidden = true; },
	unhideTextInstance: (t) => { t.__hidden = false; },
	detachDeletedInstance: () => {},

	getInstanceFromNode: () => null,
	beforeActiveInstanceBlur: () => {},
	afterActiveInstanceBlur: () => {},
	prepareScopeUpdate: () => {},
	getInstanceFromScope: () => null,
	requestPostPaintCallback: (cb) => requestAnimationFrame((t) => cb(t)),
	shouldAttemptEagerTransition: () => false,
	trackSchedulerEvent: () => {},
	resolveEventType: () => null,
	resolveEventTimeStamp: () => -1.1,
	setCurrentUpdatePriority: (p) => { currentUpdatePriority = p; },
	getCurrentUpdatePriority: () => currentUpdatePriority,
	resolveUpdatePriority: () => currentUpdatePriority || DefaultEventPriority,
	resetFormInstance: () => {},
	bindToConsole: (methodName, args, badgeName) => Function.prototype.bind.call(console[methodName], console, ...args),

	// Suspensey commits (images/stylesheets): we wait for delayRender() instead.
	maySuspendCommit: () => false,
	maySuspendCommitOnUpdate: () => false,
	maySuspendCommitInSyncRender: () => false,
	mayResourceSuspendCommit: () => false,
	preloadInstance: () => true,
	preloadResource: () => true,
	startSuspendingCommit: () => {},
	suspendInstance: () => {},
	suspendResource: () => {},
	suspendOnActiveViewTransition: () => {},
	waitForCommitToBeReady: () => null,
	getSuspendedCommitReason: () => null,

	// View transitions / fragments / gestures: not used for rendering video frames.
	startViewTransition: () => null,
	startGestureTransition: () => null,
	stopViewTransition: () => {},
	addViewTransitionFinishedListener: () => {},
	applyViewTransitionName: () => {},
	restoreViewTransitionName: () => {},
	cancelViewTransitionName: () => {},
	cancelRootViewTransitionName: () => {},
	restoreRootViewTransitionName: () => {},
	cloneRootViewTransitionContainer: () => null,
	removeRootViewTransitionClone: () => {},
	measureInstance: () => null,
	measureClonedInstance: () => null,
	wasInstanceInViewport: () => true,
	hasInstanceChanged: () => false,
	hasInstanceAffectedParent: () => false,
	createViewTransitionInstance: () => null,
	getCurrentGestureOffset: () => 0,
	createFragmentInstance: () => ({}),
	updateFragmentInstanceFiber: () => {},
	commitNewChildToFragmentInstance: () => {},
	deleteChildFromFragmentInstance: () => {},
	isSingletonScope: () => false,
	isHostSingletonType: () => false,
	isHostHoistableType: () => false,
	getHoistableRoot: () => null,
	getResource: () => null,
	acquireResource: () => null,
	releaseResource: () => {},
	prepareToCommitHoistables: () => {},
	setFocusIfFocusable: () => false,
	setupIntersectionObserver: () => ({disconnect() {}, observe() {}, unobserve() {}}),
	getBoundingRect: (el) => el.getBoundingClientRect(),
	getTextContent: (el) => el.textContent,
	isHiddenSubtree: () => false,
	matchAccessibilityRole: () => false,
	findFiberRoot: () => null,
};

const R = Reconciler(hostConfig);

const onError = (e) => { globalThis.__mr?.log?.('error', String(e?.stack ?? e)); };
const makeRoot = (container, tag) => {
	const fiberRoot = R.createContainer(container, tag, null, false, null, '', onError, onError, onError, null);
	return {
		render(children) { R.updateContainer(children, fiberRoot, null, null); },
		unmount() { R.updateContainer(null, fiberRoot, null, null); },
		_internalRoot: fiberRoot,
	};
};

export const version = React.version;
export const createRoot = (container) => makeRoot(container, ConcurrentRoot);
export const hydrateRoot = (container, children) => { const r = createRoot(container); r.render(children); return r; };
const legacyRoots = new WeakMap();
export const render = (children, container, cb) => {
	let r = legacyRoots.get(container);
	if (!r) { r = makeRoot(container, LegacyRoot); legacyRoots.set(container, r); }
	r.render(children); cb?.();
};
export const unmountComponentAtNode = (container) => { legacyRoots.get(container)?.unmount(); return true; };
export const createPortal = (children, containerInfo, key = null) => ({
	$$typeof: Symbol.for('react.portal'), key: key == null ? null : String(key), children, containerInfo, implementation: null,
});
export const flushSync = (fn) => R.flushSyncFromReconciler ? R.flushSyncFromReconciler(fn) : (R.flushSync ? R.flushSync(fn) : fn?.());
export const unstable_batchedUpdates = (fn, a) => (R.batchedUpdates ? R.batchedUpdates(fn, a) : fn(a));
export const findDOMNode = (x) => x;
export const preload = () => {}; export const preinit = () => {}; export const preconnect = () => {}; export const prefetchDNS = () => {};
export const preloadModule = () => {}; export const preinitModule = () => {};
export const useFormStatus = () => ({pending: false, data: null, method: null, action: null});
export const useFormState = (action, initial) => React.useActionState(action, initial);
export const requestFormReset = () => {};
// Some libraries import these from react-dom; they have no effect when rendering video.
export const __DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = {d: {f() {}, r() {}, D() {}, C() {}, L() {}, m() {}, X() {}, S() {}, M() {}}, p: 0, findDOMNode: null};

// Drive the reconciler synchronously from Swift: flush everything React scheduled.
globalThis.__mr_flushReact = () => { try { R.flushSyncWork?.(); } catch (e) { onError(e); } };
globalThis.__mr_reconcilerEvents = {DiscreteEventPriority};

export default {version, createRoot, hydrateRoot, render, unmountComponentAtNode, createPortal, flushSync, unstable_batchedUpdates, findDOMNode};
