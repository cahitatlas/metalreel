// Sample caption track (frames at 30 fps). Generic text, not a transcript of the clip.
export type Word = {text: string; from: number; to: number};
const line = (start: number, words: string[], per = 9): Word[] => words.map((w, i) => ({text: w, from: start + i * per, to: start + (i + 1) * per}));
export const captions: Word[][] = [
	line(10, ['This', 'video', 'was', 'rendered', 'without', 'a', 'browser.']),
	line(90, ['Captions', 'are', 'laid', 'out', 'by', 'Core', 'Text,']),
	line(170, ['with', 'the', 'same', 'line', 'breaks', 'as', 'Chrome.']),
	line(250, ['The', 'camera', 'is', 'decoded', 'in', 'hardware']),
	line(330, ['and', 'encoded', 'straight', 'from', 'the', 'GPU.']),
	line(400, ['Same', 'Remotion', 'code,', 'no', 'changes.']),
];
