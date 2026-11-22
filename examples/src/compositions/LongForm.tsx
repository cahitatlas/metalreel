// Long-form lecture / podcast layout (5 minutes): slide panel, looping camera picture-in-picture,
// captions, chapter title and progress — the kind of video where render time adds up.
import {AbsoluteFill, interpolate, Loop, OffthreadVideo, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {inter, serif} from '../fonts';

const chapters = ['Why render natively', 'The display list', 'Layout with Yoga', 'Text with Core Text', 'Painting with Metal', 'Encoding with VideoToolbox', 'Falling back to WebKit', 'Measuring the result', 'What comes next', 'Wrapping up'];
const lines = ['Every frame starts as React state.', 'Remotion turns time into props.', 'We lay out boxes without a browser.', 'Text is shaped exactly once per line.', 'The GPU composites the frame.', 'The encoder reads the same surface.'];

export const LongForm: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps, durationInFrames} = useVideoConfig();
	const chapter = Math.min(chapters.length - 1, Math.floor(frame / (30 * fps)));
	const local = frame % (30 * fps);
	const line = lines[Math.floor(frame / (5 * fps)) % lines.length];
	return (
		<AbsoluteFill style={{background: 'linear-gradient(135deg, #0f172a, #1e293b)', fontFamily: inter}}>
			<div style={{position: 'absolute', left: 80, top: 80, width: 1080, height: 760, borderRadius: 28, backgroundColor: '#f8fafc', padding: 70, display: 'flex', flexDirection: 'column', gap: 30, boxShadow: '0 30px 80px rgba(0, 0, 0, 0.4)'}}>
				<div style={{fontSize: 28, fontWeight: 600, color: '#64748b', letterSpacing: 3}}>CHAPTER {chapter + 1}</div>
				<div style={{fontFamily: serif, fontSize: 84, fontWeight: 700, color: '#0f172a', lineHeight: 1.1, opacity: interpolate(local, [0, 15], [0, 1], {extrapolateRight: 'clamp'})}}>{chapters[chapter]}</div>
				{[0, 1, 2].map((i) => (
					<div key={i} style={{fontSize: 40, color: '#334155', opacity: interpolate(local, [30 + i * 60, 45 + i * 60], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'})}}>• {lines[(chapter + i) % lines.length]}</div>
				))}
			</div>
			<div style={{position: 'absolute', right: 80, top: 80, width: 600, height: 760, borderRadius: 28, overflow: 'hidden', border: '6px solid rgba(255, 255, 255, 0.9)'}}>
				<Loop durationInFrames={500}>
					<OffthreadVideo src={staticFile('media/talking-head.mp4')} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
				</Loop>
			</div>
			<div style={{position: 'absolute', left: 80, right: 80, bottom: 120, textAlign: 'center', fontSize: 46, fontWeight: 700, color: 'white', textShadow: '0 3px 12px rgba(0, 0, 0, 0.6)'}}>{line}</div>
			<div style={{position: 'absolute', left: 80, right: 80, bottom: 60, height: 8, borderRadius: 4, backgroundColor: 'rgba(255, 255, 255, 0.15)'}}>
				<div style={{width: `${(frame / durationInFrames) * 100}%`, height: '100%', borderRadius: 4, backgroundColor: '#38bdf8'}} />
			</div>
		</AbsoluteFill>
	);
};
