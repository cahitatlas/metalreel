import {loadFont as loadInter} from '@remotion/google-fonts/Inter';
import {loadFont as loadSerif} from '@remotion/google-fonts/PlayfairDisplay';

export const inter = loadInter('normal', {weights: ['400', '600', '800'], subsets: ['latin']}).fontFamily;
export const serif = loadSerif('normal', {weights: ['700'], subsets: ['latin']}).fontFamily;
