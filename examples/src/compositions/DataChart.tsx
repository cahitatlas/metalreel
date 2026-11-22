// Data visualization: animated horizontal bar chart with ranked labels and number tickers (divs only).
import {AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {inter} from '../fonts';

const data = [
	{label: 'Static site', value: 82, color: '#5b8def'},
	{label: 'Mobile app', value: 64, color: '#33c3a1'},
	{label: 'Desktop app', value: 47, color: '#f2b544'},
	{label: 'Video pipeline', value: 91, color: '#e8615a'},
	{label: 'Data dashboard', value: 38, color: '#a77bea'},
];

export const DataChart: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const sorted = [...data].sort((a, b) => b.value - a.value);
	return (
		<AbsoluteFill style={{backgroundColor: '#0f1420', fontFamily: inter, padding: '90px 120px', color: 'white'}}>
			<div style={{fontSize: 64, fontWeight: 800}}>Render time saved per project</div>
			<div style={{fontSize: 30, color: 'rgba(255, 255, 255, 0.6)', marginTop: 12, marginBottom: 60}}>Sample data · minutes per week</div>
			{sorted.map((d, i) => {
				const grow = spring({frame: frame - 10 - i * 6, fps, config: {damping: 20, mass: 0.8}});
				const value = Math.round(d.value * grow);
				return (
					<div key={d.label} style={{display: 'flex', alignItems: 'center', height: 104, gap: 30}}>
						<div style={{width: 330, fontSize: 36, fontWeight: 600, textAlign: 'right', color: 'rgba(255, 255, 255, 0.9)'}}>{d.label}</div>
						<div style={{flex: 1, height: 64, backgroundColor: 'rgba(255, 255, 255, 0.06)', borderRadius: 12, overflow: 'hidden'}}>
							<div style={{width: `${d.value * grow}%`, height: '100%', borderRadius: 12, background: `linear-gradient(90deg, ${d.color}, ${d.color}cc)`, boxShadow: `0 0 30px ${d.color}55`}} />
						</div>
						<div style={{width: 120, fontSize: 44, fontWeight: 800, fontVariantNumeric: 'tabular-nums'}}>{value}</div>
					</div>
				);
			})}
			<div style={{position: 'absolute', right: 120, bottom: 70, fontSize: 26, color: 'rgba(255, 255, 255, 0.45)', opacity: interpolate(frame, [60, 80], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'})}}>
				Values are illustrative
			</div>
		</AbsoluteFill>
	);
};
