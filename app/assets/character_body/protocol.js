// Bounded artwork contract. No workout records, identifiers, paths or executable text.
export const regions=Object.freeze(['chest','back','shoulders','quads','hamstrings','calves','biceps','triceps']);
const keys=['version','style','scores','neutral','accent','background','theme','visible','reduced','compact','paused','yaw','turn','command','revision','retry'];
export function validateDisplay(input){
 if(!input||typeof input!=='object'||(Object.keys(input).length!==keys.length+(Object.hasOwn(input,'interaction')?1:0)+(Object.hasOwn(input,'view')?1:0))||keys.some(k=>!Object.hasOwn(input,k)))throw new Error('Invalid display state');
 if(input.version!==2||!['male','female'].includes(input.style)||!['light','dark'].includes(input.theme))throw new Error('Invalid display version/style');
 for(const k of ['visible','reduced','compact','paused'])if(typeof input[k]!=='boolean')throw new Error('Invalid display flag');
 for(const k of ['neutral','accent','background'])if(!Array.isArray(input[k])||input[k].length!==3||input[k].some(n=>!Number.isInteger(n)||n<0||n>255))throw new Error('Invalid palette');
 if(!input.scores||Object.keys(input.scores).length!==regions.length||regions.some(k=>!Number.isFinite(input.scores[k])||input.scores[k]<0||input.scores[k]>1))throw new Error('Invalid region score');
 if(!Number.isFinite(input.yaw)||input.yaw<0||input.yaw>=Math.PI*2)throw new Error('Invalid yaw');
 if(!Number.isFinite(input.turn)||input.turn<0||input.turn>=Math.PI*2)throw new Error('Invalid turn');
 for(const k of ['command','revision','retry'])if(!Number.isSafeInteger(input[k])||input[k]<0)throw new Error('Invalid command');
 if(Object.hasOwn(input,'view')){
  const v=input.view;
  if(!v||Object.keys(v).sort().join(',')!=='x,y,zoom'||!Number.isFinite(v.zoom)||v.zoom<1||v.zoom>3||['x','y'].some(k=>!Number.isFinite(v[k])||Math.abs(v[k])>(v.zoom-1)/2))throw new Error('Invalid viewport');
 }
 if(Object.hasOwn(input,'interaction')){
  const i=input.interaction;
  if(!i||Object.keys(i).sort().join(',')!=='enabled,generation,selected'||typeof i.enabled!=='boolean'||!Number.isSafeInteger(i.generation)||i.generation<0||!(i.selected===null||regions.includes(i.selected))||(!i.enabled&&i.selected!==null))throw new Error('Invalid interaction');
 }
 return input;
}

export function validatePick(input){
 if(!input||Object.keys(input).sort().join(',')!=='frame,generation,id,layout,load,version,x,y'||input.version!==2)throw new Error('Invalid pick');
 for(const key of ['id','generation','frame','load','layout'])if(!Number.isSafeInteger(input[key])||input[key]<0)throw new Error('Invalid pick identity');
 for(const key of ['x','y'])if(!Number.isFinite(input[key])||input[key]<0||input[key]>=1)throw new Error('Invalid pick coordinate');
 return input;
}
