// Developer content: a code editor window with typewriter reveal and a moving line highlight.
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {inter} from '../fonts';

const code = `export const Title = () => {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [0, 30], [0, 1]);
  return (
    <AbsoluteFill style={{opacity}}>
      <h1>Hello, native renderer</h1>
    </AbsoluteFill>
  );
};`;
const KEYWORDS = new Set(['export', 'const', 'return']);

const Token: React.FC<{t: string}> = ({t}) => {
	const color = KEYWORDS.has(t) ? '#ff7ab2' : /^[A-Z]/.test(t) ? '#7ad3ff' : /^\d+$/.test(t) ? '#d9c97c' : /^[a-z]\w*$/.test(t) ? '#e6e6e6' : '#9aa5b1';
	return <span style={{color}}>{t}</span>;
};

export const CodeWalkthrough: React.FC = () => {
	const frame = useCurrentFrame();
	const chars = Math.floor(interpolate(frame, [0, 150], [0, code.length], {extrapolateRight: 'clamp'}));
	const lines = code.slice(0, chars).split('\n');
	const focus = Math.min(lines.length - 1, Math.floor(interpolate(frame, [160, 260], [1, 6], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'})));
	return (
		<AbsoluteFill style={{background: 'linear-gradient(135deg, #3b2d6e, #10243f)', justifyContent: 'center', alignItems: 'center', fontFamily: inter}}>
			<div style={{width: 1500, borderRadius: 24, backgroundColor: '#1b1e27', boxShadow: '0 40px 100px rgba(0, 0, 0, 0.55)', overflow: 'hidden'}}>
				<div style={{height: 64, display: 'flex', alignItems: 'center', gap: 14, paddingLeft: 26, backgroundColor: '#232733'}}>
					{['#ff5f57', '#febc2e', '#28c840'].map((c) => <div key={c} style={{width: 20, height: 20, borderRadius: 10, backgroundColor: c}} />)}
					<div style={{marginLeft: 24, color: 'rgba(255, 255, 255, 0.55)', fontSize: 26}}>Title.tsx</div>
				</div>
				<div style={{padding: '30px 0', fontFamily: 'Menlo, monospace', fontSize: 38, lineHeight: 1.55}}>
					{lines.map((l, i) => (
						<div key={i} style={{display: 'flex', whiteSpace: 'pre', paddingLeft: 30, backgroundColor: frame > 160 && i === focus ? 'rgba(122, 211, 255, 0.12)' : 'transparent'}}>
							<span style={{width: 60, color: 'rgba(255, 255, 255, 0.3)'}}>{i + 1}</span>
							<span>{l.split(/(\W)/).filter(Boolean).map((t, k) => <Token key={k} t={t} />)}</span>
						</div>
					))}
				</div>
			</div>
		</AbsoluteFill>
	);
};
