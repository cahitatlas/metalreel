import {AbsoluteFill, Html5Audio, interpolate, OffthreadVideo, Sequence, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {inter, serif} from '../fonts';

const slides = [
	{title: 'Why native?', points: ['Chrome screenshots every frame', 'The GPU waits for the browser', 'Apple Silicon has idle video engines']},
	{title: 'How it works', points: ['JavaScriptCore runs the bundle', 'Yoga lays out flexbox', 'Core Text shapes every line', 'Metal paints, VideoToolbox encodes']},
	{title: 'What stays the same', points: ['Your React components', 'interpolate(), spring(), <Sequence>', 'staticFile(), fonts, audio']},
];

const Slide: React.FC<{i: number}> = ({i}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const s = slides[i];
	return (
		<AbsoluteFill style={{padding: '110px 140px', flexDirection: 'column', fontFamily: inter, color: '#13203a'}}>
			<div style={{fontFamily: serif, fontSize: 92, fontWeight: 700, marginBottom: 50, opacity: interpolate(frame, [0, 12], [0, 1], {extrapolateRight: 'clamp'})}}>{s.title}</div>
			{s.points.map((p, k) => {
				const t = spring({frame: frame - 10 - k * 8, fps, config: {damping: 18}});
				return (
					<div key={k} style={{display: 'flex', alignItems: 'center', gap: 28, marginBottom: 30, opacity: t, transform: `translateX(${(1 - t) * 60}px)`}}>
						<div style={{width: 22, height: 22, borderRadius: 11, backgroundColor: '#3b6cff'}} />
						<div style={{fontSize: 50, fontWeight: 600, maxWidth: 1000}}>{p}</div>
					</div>
				);
			})}
		</AbsoluteFill>
	);
};

export const SlideCamera: React.FC = () => {
	const frame = useCurrentFrame();
	const music = (f: number) => interpolate(f, [0, 30, 420, 450], [0, 0.35, 0.35, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
	return (
		<AbsoluteFill style={{background: 'linear-gradient(160deg, #f4f7ff 0%, #e3eaff 100%)'}}>
			{slides.map((_, i) => (
				<Sequence key={i} from={i * 150} durationInFrames={150}>
					<Slide i={i} />
				</Sequence>
			))}
			<div style={{position: 'absolute', right: 80, bottom: 80, width: 380, height: 380, borderRadius: 190, overflow: 'hidden', border: '8px solid white', boxShadow: '0 25px 60px rgba(20, 40, 90, 0.35)'}}>
				<OffthreadVideo src={staticFile('media/talking-head.mp4')} style={{width: '100%', height: '100%', objectFit: 'cover'}} volume={0} />
			</div>
			<div style={{position: 'absolute', left: 140, bottom: 70, fontFamily: inter, fontSize: 26, color: 'rgba(19, 32, 58, 0.6)', fontWeight: 600, letterSpacing: 2}}>
				SLIDE {Math.floor(frame / 150) + 1} / 3
			</div>
			<Html5Audio src={staticFile('media/ambient.wav')} volume={music} />
		</AbsoluteFill>
	);
};
