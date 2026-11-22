// Social / marketing promo: product card, price tag, feature list and CTA with @remotion/transitions.
import {AbsoluteFill, interpolate, OffthreadVideo, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {linearTiming, springTiming, TransitionSeries} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import {slide} from '@remotion/transitions/slide';
import {inter, serif} from '../fonts';

const Hero: React.FC = () => {
	const frame = useCurrentFrame();
	return (
		<AbsoluteFill>
			<OffthreadVideo src={staticFile('media/meadow.mp4')} muted style={{width: '100%', height: '100%', objectFit: 'cover', transform: `scale(${1.1 - frame / 1500})`}} />
			<AbsoluteFill style={{background: 'linear-gradient(90deg, rgba(0, 0, 0, 0.75), rgba(0, 0, 0, 0) 70%)', justifyContent: 'center', paddingLeft: 140, fontFamily: serif}}>
				<div style={{color: 'white', fontSize: 120, fontWeight: 700, lineHeight: 1}}>Weekend<br />Getaway</div>
				<div style={{color: '#ffe08a', fontFamily: inter, fontSize: 44, marginTop: 30, fontWeight: 600}}>Two nights in the countryside</div>
			</AbsoluteFill>
		</AbsoluteFill>
	);
};
const Offer: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const tag = spring({frame: frame - 10, fps, config: {damping: 9}});
	return (
		<AbsoluteFill style={{backgroundColor: '#fff7e8', fontFamily: inter, padding: 140, flexDirection: 'row', alignItems: 'center', gap: 120}}>
			<div style={{display: 'flex', flexDirection: 'column', gap: 26}}>
				{['Cabin for two', 'Breakfast included', 'Free cancellation'].map((t, i) => (
					<div key={t} style={{fontSize: 56, fontWeight: 700, color: '#2b2116', opacity: interpolate(frame, [i * 8, i * 8 + 12], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'})}}>✓ {t}</div>
				))}
			</div>
			<div style={{width: 420, height: 420, borderRadius: 210, backgroundColor: '#e8615a', display: 'flex', flexDirection: 'column', justifyContent: 'center', alignItems: 'center', color: 'white', transform: `rotate(${(1 - tag) * 25 - 8}deg) scale(${tag})`, boxShadow: '0 30px 60px rgba(232, 97, 90, 0.45)'}}>
				<div style={{fontSize: 40, fontWeight: 600}}>from</div>
				<div style={{fontSize: 150, fontWeight: 800, lineHeight: 1}}>$129</div>
			</div>
		</AbsoluteFill>
	);
};
const Cta: React.FC = () => (
	<AbsoluteFill style={{background: 'linear-gradient(135deg, #2b5876, #4e4376)', justifyContent: 'center', alignItems: 'center', fontFamily: inter}}>
		<div style={{fontSize: 90, color: 'white', fontWeight: 800}}>Book by Sunday</div>
		<div style={{marginTop: 40, padding: '26px 70px', borderRadius: 999, backgroundColor: 'white', color: '#2b2116', fontSize: 50, fontWeight: 800}}>example.com/getaway</div>
	</AbsoluteFill>
);

export const ProductPromo: React.FC = () => (
	<TransitionSeries>
		<TransitionSeries.Sequence durationInFrames={110}><Hero /></TransitionSeries.Sequence>
		<TransitionSeries.Transition presentation={slide({direction: 'from-right'})} timing={springTiming({config: {damping: 200}, durationInFrames: 25})} />
		<TransitionSeries.Sequence durationInFrames={110}><Offer /></TransitionSeries.Sequence>
		<TransitionSeries.Transition presentation={fade()} timing={linearTiming({durationInFrames: 20})} />
		<TransitionSeries.Sequence durationInFrames={95}><Cta /></TransitionSeries.Sequence>
	</TransitionSeries>
);
