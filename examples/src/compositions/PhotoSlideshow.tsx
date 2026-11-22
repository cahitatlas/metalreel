// Photo memories: Ken Burns pans over still images with cross-fades and a caption strip.
import {AbsoluteFill, Img, interpolate, Sequence, staticFile, useCurrentFrame} from 'remotion';
import {serif} from '../fonts';

const photos = [
	{src: 'img/photo-1.jpg', caption: 'Morning walk', from: [1.0, 0, 0], to: [1.15, -40, -20]},
	{src: 'img/photo-2.jpg', caption: 'Up north', from: [1.2, 30, 0], to: [1.05, -30, 10]},
	{src: 'img/photo-3.jpg', caption: 'Last light', from: [1.05, 0, 30], to: [1.2, 20, -30]},
];
const LEN = 100, FADE = 20;

const Photo: React.FC<{i: number}> = ({i}) => {
	const frame = useCurrentFrame();
	const p = photos[i];
	const t = frame / (LEN + FADE);
	const s = p.from[0] + (p.to[0] - p.from[0]) * t, x = p.from[1] + (p.to[1] - p.from[1]) * t, y = p.from[2] + (p.to[2] - p.from[2]) * t;
	const opacity = interpolate(frame, [0, FADE, LEN, LEN + FADE], [0, 1, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
	return (
		<AbsoluteFill style={{opacity}}>
			<Img src={staticFile(p.src)} style={{width: '100%', height: '100%', objectFit: 'cover', transform: `scale(${s}) translate(${x}px, ${y}px)`}} />
			<div style={{position: 'absolute', left: 0, right: 0, bottom: 0, padding: '40px 80px', background: 'linear-gradient(to top, rgba(0, 0, 0, 0.6), rgba(0, 0, 0, 0))', color: 'white', fontFamily: serif, fontSize: 64}}>{p.caption}</div>
		</AbsoluteFill>
	);
};

export const PhotoSlideshow: React.FC = () => (
	<AbsoluteFill style={{backgroundColor: 'black'}}>
		{photos.map((_, i) => <Sequence key={i} from={i * LEN} durationInFrames={LEN + FADE}><Photo i={i} /></Sequence>)}
	</AbsoluteFill>
);
