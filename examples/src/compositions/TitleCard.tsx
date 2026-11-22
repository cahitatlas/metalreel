import {AbsoluteFill, interpolate, OffthreadVideo, spring, staticFile, useCurrentFrame, useVideoConfig, Easing} from 'remotion';
import {inter, serif} from '../fonts';

export const TitleCard: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const pop = spring({frame, fps, config: {damping: 14, stiffness: 120}});
	const fade = interpolate(frame, [0, 20], [0, 1], {extrapolateRight: 'clamp'});
	const slide = interpolate(frame, [10, 45], [80, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic)});
	const progress = interpolate(frame, [0, 149], [0, 100]);
	const hue = interpolate(frame, [0, 149], [220, 260]);
	return (
		<AbsoluteFill style={{background: `linear-gradient(135deg, hsl(${hue}, 70%, 18%) 0%, #0b1020 60%, #1d0f2e 100%)`, fontFamily: inter}}>
			<AbsoluteFill style={{background: 'radial-gradient(circle at 80% 20%, rgba(120, 160, 255, 0.35), rgba(0, 0, 0, 0) 45%)'}} />
			<div style={{position: 'absolute', left: 120, top: 150, width: 860, display: 'flex', flexDirection: 'column', gap: 28, opacity: fade, transform: `translateY(${slide}px)`}}>
				<div style={{alignSelf: 'flex-start', padding: '10px 22px', borderRadius: 999, background: 'rgba(255, 255, 255, 0.12)', border: '2px solid rgba(255, 255, 255, 0.35)', color: '#cfe0ff', fontSize: 30, fontWeight: 600, letterSpacing: 4}}>
					NATIVE RENDER
				</div>
				<div style={{fontFamily: serif, fontSize: 112, lineHeight: 1.05, color: 'white', fontWeight: 700, textShadow: '0 6px 30px rgba(0, 0, 0, 0.45)'}}>
					React video, drawn by Metal.
				</div>
				<div style={{fontSize: 40, lineHeight: 1.4, color: 'rgba(230, 236, 255, 0.85)', maxWidth: 760}}>
					The same Remotion composition, rendered without a browser: JavaScriptCore, Yoga, Core Text and VideoToolbox.
				</div>
			</div>
			<div style={{position: 'absolute', right: 120, top: 190, width: 620, height: 700, borderRadius: 36, overflow: 'hidden', transform: `scale(${0.85 + 0.15 * pop}) rotate(${(1 - pop) * -6}deg)`, boxShadow: '0 40px 80px rgba(0, 0, 0, 0.5)', border: '4px solid rgba(255, 255, 255, 0.85)'}}>
				<OffthreadVideo src={staticFile('media/meadow.mp4')} muted style={{width: '100%', height: '100%', objectFit: 'cover'}} />
				<div style={{position: 'absolute', left: 0, right: 0, bottom: 0, height: 180, background: 'linear-gradient(to bottom, rgba(0, 0, 0, 0), rgba(0, 0, 0, 0.7))'}} />
				<div style={{position: 'absolute', left: 32, bottom: 30, color: 'white', fontSize: 34, fontWeight: 800}}>Hardware decoded</div>
			</div>
			<div style={{position: 'absolute', left: 120, right: 120, bottom: 90, height: 10, borderRadius: 5, background: 'rgba(255, 255, 255, 0.15)'}}>
				<div style={{width: `${progress}%`, height: '100%', borderRadius: 5, background: 'linear-gradient(90deg, #6ea8ff, #c084fc)'}} />
			</div>
		</AbsoluteFill>
	);
};
