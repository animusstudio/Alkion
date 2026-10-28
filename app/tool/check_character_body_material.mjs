import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {sampleSurfaceCell,materialGlyph,materialAlpha,columnPhase} from '../assets/character_body/material.js';

// Frozen output digests from the accepted sampler, before optimization. The
// cases describe synthetic surfaces, rather than duplicating its algorithm.
const expected={occupancy:'f4bc464f43fddaab00c5488d06de5381e53162e5caa58ece74e928732e6a01f3',boundaries:'cf88bec20911f8b95f3f01d555a2736cccc6f4d0a1f8338ee82f6455b962d57f',depth:'347d7415d7ef41d0ff4cb948a4ba40908206d0ac55e53eb9dda54946dbb46bdb'};
const scratch={};let samples=0;
function digest(cases){
 const hash=createHash('sha256');
 for(const [pixels,width,height,col,row,compact,phase] of cases){
  const cell=sampleSurfaceCell(pixels,width,height,col,row,compact,phase,scratch);
  assert.ok(cell===null||cell===scratch,'Renderer can reuse its cell storage');
  const output=cell===null?null:[cell.shade,cell.region,cell.at,cell.coverage,cell.gx,cell.gy,
   materialGlyph(cell.shade,col,row,cell),materialAlpha(cell.shade,'dark',cell.coverage,compact),materialAlpha(cell.shade,'light',cell.coverage,compact)];
  hash.update(JSON.stringify(output)+'\n');samples++;
 }
 return hash.digest('hex');
}
function surface(width,height,depth,light=()=>180,inside=()=>true){
 const pixels=new Uint8Array(width*height*4);
 for(let y=0;y<height;y++)for(let x=0;x<width;x++)if(inside(x,y))pixels.set([light(x,y),(x+3*y)%9,depth(x,y),255],(y*width+x)*4);
 return pixels;
}
function* occupancy(){
 // Every possible 3×3 occupancy pattern, with center/fallback anchors and each
 // fixed phase. Outside samples contain recesses and depth discontinuities.
 for(const compact of [false,true])for(const phase of [-1,0,1])for(let mask=0;mask<512;mask++){
  const pixels=surface(21,21,(x,y)=>128+Math.min(15,Math.abs(x-10)+Math.abs(y-10)),(x,y)=>41+(x*7+y*11)%215);
  for(let i=0;i<9;i++)pixels[((20-(9+Math.floor(i/3)+phase))*21+9+i%3)*4+3]=mask&(1<<i)?255:0;
  yield [pixels,21,21,3,3,compact,phase];
 }
}
function* boundaries(){
 for(const width of [1,2,3,7,12])for(const height of [1,2,3,8,13]){
  const pixels=surface(width,height,(x,y)=>x<width/2?116:140,(x,y)=>41+(x*33+y*19)%215,(x,y)=>(x+2*y)%4!==0);
  for(const compact of [false,true])for(const phase of [-1,0,1])
   for(let row=-1;row<=Math.ceil(height/3);row++)for(let col=-1;col<=Math.ceil(width/3);col++)
    yield [pixels,width,height,col,row,compact,phase];
 }
}
function* depth(){
 // Include both sides of each depth cutoff, flat/sloping/convex/recessed forms,
 // all source light values and deterministic irregular occupancy/occlusion.
 for(const compact of [false,true])for(let light=0;light<=255;light++)for(const delta of [-13,-12,-7,-6,0,6,7,12,13]){
  const pixels=surface(21,21,(x,y)=>x===10&&y===10?128:128+delta,()=>light);
  yield [pixels,21,21,3,3,compact,0];
 }
 let seed=48371;const random=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed;};
 for(let i=0;i<2048;i++){
  const width=3+random()%30,height=3+random()%30;
  const pixels=surface(width,height,()=>random()%256,()=>random()%256,()=>random()%7>1);
  yield [pixels,width,height,random()%Math.ceil(width/3),random()%Math.ceil(height/3),!!(i%2),columnPhase(i)];
 }
}
for(const [name,cases] of [['occupancy',occupancy],['boundaries',boundaries],['depth',depth]]){
 const actual=digest(cases());assert.equal(actual,expected[name],`${name}: accepted shade/region/anchor/coverage/edge/glyph/alpha outputs changed`);
}
const pixels=surface(21,21,()=>128),original=pixels.slice();
sampleSurfaceCell(pixels,21,21,3,3,false,0,scratch);assert.deepEqual(pixels,original,'Sampling never mutates source pixels');
console.log(`PASS: ${samples} frozen-reference material cases, both themes/optical sizes, all occupancy masks, boundaries/depth cutoffs, reusable output and immutable pixels`);
