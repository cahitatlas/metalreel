// Personalized "year in review" (Wrapped-style): stat cards driven by input props, one per sequence.
import {AbsoluteFill, interpolate, Sequence, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {inter, serif} from '../fonts';

export type YearInReviewProps = {name: string; year: number; stats: {label: string; value: number; suffix: string}[]};
export const yearInReviewDefaults: YearInReviewProps = {
	name: 'Alex', year: 2026,
	stats: [{label: 'videos rendered', value: 1284, suffix: ''}, {label: 'hours saved', value: 312, suffix: 'h'}, {label: 'longest render', value: 47, suffix: ' min'}],
};

const Counter: React.FC<{value: number; suffix: string; label: string; hue: number}> = ({value, suffix, label, hue}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const p = spring({frame, fps, config: {damping: 200}, durationInFrames: 40});
	return (
		<AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', background: `radial-gradient(circle at 50% 40%, hsl(${hue}, 80%, 55%), hsl(${hue + 40}, 70%, 18%))`}}>
			<div style={{fontFamily: inter, fontWeight: 800, fontSize: 230, color: 'white', transform: `scale(${0.6 + 0.4 * p})`, textShadow: '0 12px 40px rgba(0, 0, 0, 0.35)'}}>
				{Math.round(value * p).toLocaleString('en-US')}{suffix}
			</div>
			<div style={{fontFamily: inter, fontSize: 64, fontWeight: 600, color: 'rgba(255, 255, 255, 0.9)', opacity: interpolate(frame, [15, 30], [0, 1], {extrapolateRight: 'clamp'})}}>{label}</div>
		</AbsoluteFill>
	);
};

export const YearInReview: React.FC<YearInReviewProps> = ({name, year, stats}) => {
	const frame = useCurrentFrame();
	return (
		<AbsoluteFill style={{backgroundColor: '#111'}}>
			<Sequence durationInFrames={60}>
				<AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', background: 'linear-gradient(160deg, #1b1446, #3a0f3f)'}}>
					<div style={{fontFamily: serif, fontSize: 120, color: 'white', textAlign: 'center', lineHeight: 1.1, opacity: interpolate(frame, [0, 15], [0, 1])}}>{name}'s<br />{year} in video</div>
				</AbsoluteFill>
			</Sequence>
			{stats.map((s, i) => (
				<Sequence key={i} from={60 + i * 60} durationInFrames={60}>
					<Counter {...s} hue={200 + i * 50} />
				</Sequence>
			))}
		</AbsoluteFill>
	);
};
