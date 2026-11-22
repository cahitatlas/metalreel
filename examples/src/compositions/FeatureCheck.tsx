// Native-coverage check: one panel per feature (a-h) in a 4x2 grid. Compare MetalReel against Remotion.
import {AbsoluteFill, Freeze, Img, Series, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {inter} from '../fonts';

export type FeatureCheckProps = {segments: number[]};
export const featureCheckDefaults: FeatureCheckProps = {segments: [60, 60]};
// durationInFrames computed from the props array (default 120)
export const featureCheckMetadata = ({props}: {props: FeatureCheckProps}) => ({
	durationInFrames: props.segments.reduce((a, b) => a + b, 0),
});

const FONT = `${inter}, 'Helvetica Neue', Arial, sans-serif`;
const W = 456, H = 500;

const Panel: React.FC<{label: string; col: number; row: number; children: React.ReactNode}> = ({label, col, row, children}) => (
	<div style={{position: 'absolute', left: 40 + col * (W + 16), top: 30 + row * (H + 20), width: W, height: H, backgroundColor: '#1d2433', borderRadius: 12, overflow: 'hidden'}}>
		<div style={{position: 'absolute', left: 0, top: 0, right: 0, height: 36, backgroundColor: '#35405a', color: '#ffffff', fontFamily: FONT, fontSize: 18, fontWeight: 600, padding: '7px 14px'}}>{label}</div>
		<div style={{position: 'absolute', left: 0, top: 36, right: 0, bottom: 0}}>{children}</div>
	</div>
);

const Counter: React.FC<{name: string; color: string}> = ({name, color}) => {
	const f = useCurrentFrame();
	return <div style={{color, fontFamily: FONT, fontSize: 26, fontWeight: 600, marginBottom: 8}}>{name}: frame {f}</div>;
};

const text: React.CSSProperties = {color: '#e8ecf5', fontFamily: FONT, fontSize: 24};

export const FeatureCheck: React.FC<FeatureCheckProps> = ({segments}) => {
	const {durationInFrames} = useVideoConfig();
	return (
		<AbsoluteFill style={{backgroundColor: '#0b0f18'}}>
			{/* a: calculateMetadata */}
			<Panel label="a  calculateMetadata" col={0} row={0}>
				<div style={{...text, padding: 20}}>
					<div>durationInFrames = {durationInFrames}</div>
					<div style={{marginTop: 10}}>props.segments = [{segments.join(', ')}]</div>
					<div style={{marginTop: 10, color: '#8fd18f'}}>expect 120</div>
				</div>
			</Panel>

			{/* b: Series + Freeze */}
			<Panel label="b  Series + Freeze(10)" col={1} row={0}>
				<div style={{padding: 20}}>
					<Series>
						<Series.Sequence durationInFrames={segments[0]}>
							<div><Counter name="seq 1" color="#ffd166" /><div style={text}>first sequence</div></div>
						</Series.Sequence>
						<Series.Sequence durationInFrames={segments[1]}>
							<div>
								<Counter name="seq 2" color="#06d6a0" />
								<Freeze frame={10}><Counter name="frozen" color="#ef476f" /></Freeze>
							</div>
						</Series.Sequence>
					</Series>
				</div>
			</Panel>

			{/* c: Arabic RTL + Turkish diacritics */}
			<Panel label="c  Arabic RTL / Turkish" col={2} row={0}>
				<div style={{padding: 20}}>
					<div style={{...text, direction: 'rtl', textAlign: 'right', fontSize: 40}}>مرحبا بالعالم</div>
					<div style={{...text, direction: 'rtl', textAlign: 'right', fontSize: 28, marginTop: 14, fontFamily: `${inter}, 'Geeza Pro', sans-serif`}}>هذا نص تجريبي قصير للتحقق</div>
					<div style={{...text, marginTop: 24, fontSize: 28}}>Çağrı ışığı göründü — ĞÜŞİÖÇ</div>
					<div style={{...text, marginTop: 10, fontSize: 28, fontFamily: 'Helvetica Neue, Arial'}}>ığüşiöç İĞÜŞÖÇ (system)</div>
				</div>
			</Panel>

			{/* d: background-image cover */}
			<Panel label="d  background-image cover" col={3} row={0}>
				<div style={{margin: 20, width: 416, height: 300, borderRadius: 8, backgroundImage: `url(${staticFile('img/photo-1.jpg')})`, backgroundSize: 'cover', backgroundPosition: 'center'}} />
			</Panel>

			{/* e: inline mixed styles */}
			<Panel label="e  inline styles" col={0} row={1}>
				<p style={{...text, margin: 0, padding: 20, lineHeight: 1.4}}>
					Plain text, <span style={{color: '#ff6b6b', fontWeight: 800}}>bold red</span>, <span style={{color: '#4dd0e1', fontStyle: 'italic'}}>italic cyan</span>.
					<br />
					<span style={{letterSpacing: '0.3em', color: '#ffd166'}}>spaced out</span> <span style={{textTransform: 'uppercase', color: '#b794f6'}}>upper case me</span>
				</p>
			</Panel>

			{/* f: Img objectFit contain + circle crop */}
			<Panel label="f  Img contain / circle" col={1} row={1}>
				<div style={{position: 'absolute', left: 20, top: 20, width: 200, height: 300, backgroundColor: '#000'}}>
					<Img src={staticFile('img/photo-2.jpg')} style={{width: '100%', height: '100%', objectFit: 'contain'}} />
				</div>
				<div style={{position: 'absolute', left: 240, top: 20, width: 190, height: 190, borderRadius: '50%', overflow: 'hidden'}}>
					<Img src={staticFile('img/photo-3.jpg')} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
				</div>
			</Panel>

			{/* g: zIndex + rotate/skew with transformOrigin */}
			<Panel label="g  zIndex / transform" col={2} row={1}>
				<div style={{position: 'absolute', left: 30, top: 30, width: 150, height: 150, backgroundColor: '#ef476f', zIndex: 1, color: '#fff', fontFamily: FONT, padding: 8}}>z1 (back)</div>
				<div style={{position: 'absolute', left: 90, top: 70, width: 150, height: 150, backgroundColor: '#06d6a0', zIndex: 3, color: '#000', fontFamily: FONT, padding: 8}}>z3 (front)</div>
				<div style={{position: 'absolute', left: 60, top: 50, width: 150, height: 150, backgroundColor: '#ffd166', zIndex: 2, color: '#000', fontFamily: FONT, padding: 8}}>z2 (mid)</div>
				<div style={{position: 'absolute', left: 250, top: 240, width: 160, height: 100, backgroundColor: '#118ab2', transform: 'rotate(12deg) skewX(8deg)', transformOrigin: 'top left', color: '#fff', fontFamily: FONT, padding: 8}}>rot+skew</div>
				<div style={{position: 'absolute', left: 250, top: 240, width: 4, height: 4, backgroundColor: '#fff'}} />
			</Panel>

			{/* h: justify + grid */}
			<Panel label="h  justify / grid" col={3} row={1}>
				<div style={{...text, fontSize: 18, textAlign: 'justify', width: 300, margin: '12px 20px', lineHeight: 1.3}}>
					Justified text should stretch every full line to the same width so both edges look straight, except for the very last line of the paragraph.
				</div>
				<div style={{display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, margin: '0 20px'}}>
					{['1', '2', '3', '4', '5', '6'].map((n) => (
						<div key={n} style={{height: 50, backgroundColor: '#5e60ce', color: '#fff', fontFamily: FONT, fontSize: 22, padding: 10}}>{n}</div>
					))}
				</div>
			</Panel>
		</AbsoluteFill>
	);
};
