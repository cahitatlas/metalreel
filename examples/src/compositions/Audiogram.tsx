// Podcast audiogram: cover art, animated waveform bars, title and captions over an audio track.
// The bars use deterministic pseudo-levels (random(seed)) so the sample needs no audio analysis.
import {AbsoluteFill, Html5Audio, interpolate, random, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {inter} from '../fonts';

const BARS = 48;
export const Audiogram: React.FC = () => {
	const frame = useCurrentFrame();
	const {durationInFrames} = useVideoConfig();
	const level = (i: number) => {
		const env = 0.35 + 0.65 * Math.abs(Math.sin(frame / 9 + i / 5));
		return 0.12 + 0.88 * env * random(`bar-${i}-${Math.floor(frame / 2)}`);
	};
	return (
		<AbsoluteFill style={{background: 'linear-gradient(180deg, #1d2b53 0%, #0b1022 100%)', fontFamily: inter, alignItems: 'center', paddingTop: 150}}>
			<div style={{width: 560, height: 560, borderRadius: 40, background: 'conic-gradient(from 210deg, #ff7a59, #ffcc4d, #7ad3ff, #ff7a59)', display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: '0 30px 80px rgba(0, 0, 0, 0.5)'}}>
				<div style={{fontSize: 96, fontWeight: 800, color: '#101528', textAlign: 'center', lineHeight: 1}}>THE<br />RENDER<br />SHOW</div>
			</div>
			<div style={{marginTop: 70, fontSize: 54, fontWeight: 800, color: 'white'}}>Episode 12 · Native pipelines</div>
			<div style={{marginTop: 12, fontSize: 32, color: 'rgba(255, 255, 255, 0.6)'}}>A sample podcast clip</div>
			<div style={{marginTop: 80, height: 260, display: 'flex', alignItems: 'center', gap: 8}}>
				{Array.from({length: BARS}, (_, i) => (
					<div key={i} style={{width: 12, height: 260 * level(i), borderRadius: 6, backgroundColor: i % 2 ? '#7ad3ff' : '#ffcc4d'}} />
				))}
			</div>
			<div style={{position: 'absolute', left: 90, right: 90, bottom: 160, height: 8, borderRadius: 4, backgroundColor: 'rgba(255, 255, 255, 0.15)'}}>
				<div style={{width: `${interpolate(frame, [0, durationInFrames], [0, 100])}%`, height: '100%', borderRadius: 4, backgroundColor: 'white'}} />
			</div>
			<Html5Audio src={staticFile('media/ambient.wav')} volume={0.6} />
		</AbsoluteFill>
	);
};
