import {AbsoluteFill, interpolate, OffthreadVideo, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {inter} from '../fonts';
import {captions} from './captions';

const Caption: React.FC<{frame: number}> = ({frame}) => {
	const words = captions.find((l) => frame >= l[0].from && frame < l[l.length - 1].to + 12);
	if (!words) return null;
	return (
		<div style={{position: 'absolute', left: 70, right: 70, bottom: 360, textAlign: 'center', fontFamily: inter, fontSize: 68, fontWeight: 800, lineHeight: 1.2, color: 'white', textShadow: '0 4px 18px rgba(0, 0, 0, 0.6)'}}>
			{words.map((w, i) => (
				<span key={i} style={{color: frame >= w.from && frame < w.to ? '#ffd34d' : 'white'}}>
					{w.text}{i < words.length - 1 ? ' ' : ''}
				</span>
			))}
		</div>
	);
};

export const TalkingHead: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const tag = spring({frame: frame - 20, fps, config: {damping: 200}});
	const zoom = interpolate(frame, [0, 480], [1.0, 1.08]);
	return (
		<AbsoluteFill style={{backgroundColor: 'black'}}>
			<AbsoluteFill style={{transform: `scale(${zoom})`}}>
				<OffthreadVideo src={staticFile('media/talking-head.mp4')} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
			</AbsoluteFill>
			<AbsoluteFill style={{background: 'linear-gradient(to bottom, rgba(0, 0, 0, 0) 55%, rgba(0, 0, 0, 0.55) 100%)'}} />
			<div style={{position: 'absolute', left: 60, top: 140, display: 'flex', flexDirection: 'column', gap: 6, padding: '22px 30px', borderRadius: 20, backgroundColor: 'rgba(15, 18, 30, 0.72)', borderLeft: '8px solid #ffd34d', fontFamily: inter, transform: `translateX(${(1 - tag) * -500}px)`}}>
				<div style={{color: 'white', fontSize: 44, fontWeight: 800}}>Sample Speaker</div>
				<div style={{color: 'rgba(255, 255, 255, 0.75)', fontSize: 30, fontWeight: 400}}>Talking-head demo · open-license clip</div>
			</div>
			<Caption frame={frame} />
		</AbsoluteFill>
	);
};
