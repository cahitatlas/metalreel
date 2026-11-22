import {Composition} from 'remotion';
import {TitleCard} from './compositions/TitleCard';
import {TalkingHead} from './compositions/TalkingHead';
import {SlideCamera} from './compositions/SlideCamera';
import {VerticalClip} from './compositions/VerticalClip';
import {DataChart} from './compositions/DataChart';
import {YearInReview, yearInReviewDefaults} from './compositions/YearInReview';
import {Audiogram} from './compositions/Audiogram';
import {CodeWalkthrough} from './compositions/CodeWalkthrough';
import {ProductPromo} from './compositions/ProductPromo';
import {PhotoSlideshow} from './compositions/PhotoSlideshow';
import {LongForm} from './compositions/LongForm';

export const Root: React.FC = () => (
	<>
		{/* animated title: gradient, box, text, spring/interpolate, video in a rounded frame */}
		<Composition id="TitleCard" component={TitleCard} width={1920} height={1080} fps={30} durationInFrames={150} />
		{/* talking head with word-highlighted captions and a lower third */}
		<Composition id="TalkingHead" component={TalkingHead} width={1080} height={1920} fps={30} durationInFrames={480} />
		{/* slides + circular camera picture-in-picture + background music */}
		<Composition id="SlideCamera" component={SlideCamera} width={1920} height={1080} fps={30} durationInFrames={450} />
		{/* vertical social cut: hook text, SVG icon, progress bar, call to action */}
		<Composition id="VerticalClip" component={VerticalClip} width={1080} height={1920} fps={30} durationInFrames={300} />
		{/* data visualization: bar chart with springs and number tickers */}
		<Composition id="DataChart" component={DataChart} width={1920} height={1080} fps={30} durationInFrames={150} />
		{/* personalized year-in-review driven by input props (try --props '{"name":"Sam"}') */}
		<Composition id="YearInReview" component={YearInReview} width={1080} height={1920} fps={30} durationInFrames={240} defaultProps={yearInReviewDefaults} />
		{/* podcast audiogram: cover, waveform bars, progress, audio track */}
		<Composition id="Audiogram" component={Audiogram} width={1080} height={1920} fps={30} durationInFrames={300} />
		{/* developer content: code typewriter with line highlight */}
		<Composition id="CodeWalkthrough" component={CodeWalkthrough} width={1920} height={1080} fps={30} durationInFrames={270} />
		{/* marketing promo with @remotion/transitions (slide + fade) */}
		<Composition id="ProductPromo" component={ProductPromo} width={1920} height={1080} fps={30} durationInFrames={270} />
		{/* photo memories: Ken Burns + cross-fades */}
		<Composition id="PhotoSlideshow" component={PhotoSlideshow} width={1920} height={1080} fps={30} durationInFrames={320} />
		{/* long-form lecture layout, 5 minutes: slides + looping camera + captions (for long-render benchmarks) */}
		<Composition id="LongForm" component={LongForm} width={1920} height={1080} fps={30} durationInFrames={9000} />
	</>
);
