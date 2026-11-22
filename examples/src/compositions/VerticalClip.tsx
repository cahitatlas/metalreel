import {AbsoluteFill, interpolate, OffthreadVideo, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {inter} from '../fonts';

const Bolt: React.FC<{size: number}> = ({size}) => (
	<svg width={size} height={size} viewBox="0 0 24 24">
		<defs>
			<linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
				<stop offset="0%" stopColor="#ffe066" />
				<stop offset="100%" stopColor="#ff8a00" />
			</linearGradient>
		</defs>
		<path d="M13 2L3 14h7l-1 8 10-12h-7l1-8z" fill="url(#g)" stroke="white" strokeWidth={1.2} strokeLinejoin="round" />
	</svg>
);

export const VerticalClip: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps, durationInFrames} = useVideoConfig();
	const hook = spring({frame, fps, config: {damping: 12}});
	const cta = spring({frame: frame - 210, fps, config: {damping: 10}});
	const pulse = 1 + 0.06 * Math.sin(frame / 6);
	return (
		<AbsoluteFill style={{backgroundColor: '#000'}}>
			<OffthreadVideo src={staticFile('media/vertical.mp4')} muted style={{width: '100%', height: '100%', objectFit: 'cover'}} />
			<AbsoluteFill style={{background: 'linear-gradient(to bottom, rgba(0, 0, 0, 0.65) 0%, rgba(0, 0, 0, 0) 35%, rgba(0, 0, 0, 0) 60%, rgba(0, 0, 0, 0.7) 100%)'}} />
			<div style={{position: 'absolute', top: 230, left: 80, right: 80, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 30, transform: `scale(${0.7 + 0.3 * hook})`, opacity: hook}}>
				<div style={{transform: `scale(${pulse})`}}><Bolt size={150} /></div>
				<div style={{fontFamily: inter, fontWeight: 800, fontSize: 92, lineHeight: 1.08, color: 'white', textAlign: 'center', textShadow: '0 6px 24px rgba(0, 0, 0, 0.7)'}}>
					4× faster renders on your Mac
				</div>
			</div>
			<div style={{position: 'absolute', left: 140, right: 140, bottom: 330, display: 'flex', justifyContent: 'center', transform: `translateY(${(1 - cta) * 300}px)`}}>
				<div style={{padding: '28px 60px', borderRadius: 999, backgroundColor: '#ffd34d', color: '#1a1300', fontFamily: inter, fontSize: 52, fontWeight: 800, boxShadow: '0 18px 40px rgba(0, 0, 0, 0.45)'}}>
					Try it on your project
				</div>
			</div>
			<div style={{position: 'absolute', left: 0, bottom: 0, height: 14, width: `${interpolate(frame, [0, durationInFrames - 1], [0, 100])}%`, backgroundColor: '#ffd34d'}} />
		</AbsoluteFill>
	);
};
