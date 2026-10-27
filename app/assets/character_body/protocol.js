// Display-only contract. No workout records, identifiers, paths or executable text.
export const regions=Object.freeze(['chest','back','shoulders','quads','hamstrings','calves','biceps','triceps']);
const keys=['version','style','scores','neutral','accent','background','theme','visible','reduced','compact','paused','yaw','command','retry'];
export function validateDisplay(input){
 if(!input||typeof input!=='object'||Object.keys(input).length!==keys.length||keys.some(k=>!Object.hasOwn(input,k)))throw new Error('Invalid display state');
 if(input.version!==1||!['male','female'].includes(input.style)||!['light','dark'].includes(input.theme))throw new Error('Invalid display version/style');
 for(const k of ['visible','reduced','compact','paused'])if(typeof input[k]!=='boolean')throw new Error('Invalid display flag');
 for(const k of ['neutral','accent','background'])if(!Array.isArray(input[k])||input[k].length!==3||input[k].some(n=>!Number.isInteger(n)||n<0||n>255))throw new Error('Invalid palette');
 if(!input.scores||Object.keys(input.scores).length!==regions.length||regions.some(k=>!Number.isFinite(input.scores[k])||input.scores[k]<0||input.scores[k]>1))throw new Error('Invalid region score');
 if(!Number.isFinite(input.yaw)||input.yaw<0||input.yaw>=Math.PI*2)throw new Error('Invalid yaw');
 for(const k of ['command','retry'])if(!Number.isSafeInteger(input[k])||input[k]<0)throw new Error('Invalid command');
 return input;
}
