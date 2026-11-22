// Builds the JavaScript runtime pieces:
//   dist/react-dom.cjs   — our react-dom replacement (react-reconciler + scheduler bundled, `react` left external
//                          so webpack resolves the project's own copy). Aliased into the Remotion bundle in native mode.
//   ../Sources/metalreel/Resources/prelude.js — browser shims evaluated by JavaScriptCore before the bundle.
import {build} from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
await build({
	entryPoints: [path.join(here, 'runtime/react-dom.js')],
	outfile: path.join(here, 'dist/react-dom.cjs'),
	bundle: true, format: 'cjs', platform: 'neutral', mainFields: ['main'], target: 'es2022', minifySyntax: true,
	external: ['react', 'react/jsx-runtime'],
	define: {'process.env.NODE_ENV': '"production"'},
	legalComments: 'inline', logLevel: 'warning',
});
fs.copyFileSync(path.join(here, 'runtime/prelude.js'), path.join(here, '../Sources/metalreel/Resources/prelude.js'));
console.log('built js/dist/react-dom.cjs and Resources/prelude.js');
