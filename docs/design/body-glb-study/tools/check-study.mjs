#!/usr/bin/env node
import assert from 'node:assert/strict';
import {runInNewContext} from 'node:vm';
import fs from 'node:fs';import path from 'node:path';import {fileURLToPath} from 'node:url';import {spawnSync} from 'node:child_process';
import {calculateWorkload,canonicalMuscles} from '../workload.js';
import {glyphAlphabet,glyphInk,columnPhase,glyphCoverage,shapePlaneLight,sampleSurfaceCell,materialGlyph,materialAlpha,regionColor} from '../material.js';
import {TURN_MS,canAnimate,advanceYaw,MotionLoop} from '../motion.js';
import {VolumeRenderer} from '../renderer.js';
import {physiqueScale,balancePoint,fullerMesh,bodyFit} from '../geometry.js';
import {sourceMesh as retainSourceMesh} from '../source-geometry.js';
import {createHash} from 'node:crypto';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),read=name=>fs.readFileSync(path.join(root,name));
// Exercise the production transform with asymmetric geometry and a duplicated
// seam, then independently differentiate its position field through the blends.
const sub=(a,b)=>a.map((v,i)=>v-b[i]),dot=(a,b)=>a.reduce((sum,v,i)=>sum+v*b[i],0);
const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
const vertex=(positions,index)=>Array.from(positions.slice(index*3,index*3+3));
const syntheticPositions=new Float32Array([-.5,-1,-.2,.5,-.6,.1,-.2,1,.3,.2,.2,-.3,-.5,-1,-.2]);
const sourceNormal=cross(sub(vertex(syntheticPositions,1),vertex(syntheticPositions,0)),sub(vertex(syntheticPositions,2),vertex(syntheticPositions,0)));
const unitNormal=sourceNormal.map(v=>v/Math.hypot(...sourceNormal));
const sourceMesh={positions:syntheticPositions,normals:new Float32Array(Array.from({length:5},()=>unitNormal).flat()),
 indices:new Uint32Array([0,1,2,0,3,1,1,3,2,2,3,4]),uv:new Float32Array([0,0,1,0,0,1,1,1,.5,.5]),
 regions:new Uint8Array([1,2,3,0]),manifest:{bounds:[[-.5,-1,-.3],[.5,1,.3]]},masks:{}};
const originalMesh=structuredClone(sourceMesh),fuller=fullerMesh(sourceMesh);
assert.deepEqual(sourceMesh,originalMesh,'Source geometry and manifest stay untouched');
assert.deepEqual(fullerMesh(sourceMesh),fuller,'Physique transform is deterministic');
assert.equal(fuller.positions.length,sourceMesh.positions.length);assert.equal(fuller.normals.length,sourceMesh.normals.length);
for(const name of ['indices','uv','regions','manifest','masks'])assert.equal(fuller[name],sourceMesh[name],name+' preserves source identity and order');
assert.ok(physiqueScale[0]>1&&physiqueScale[0]<=1.15&&physiqueScale[2]>1&&physiqueScale[2]<=1.2,'Moderate transverse gains');
assert.equal(physiqueScale[1],1,'Source height is unchanged');
for(let at=0;at<fuller.positions.length;at++){
 assert.ok(Number.isFinite(fuller.positions[at])&&Number.isFinite(fuller.normals[at]));
 const base=at-at%3,mapped=balancePoint(...sourceMesh.positions.slice(base,base+3)).position;
 assert.equal(fuller.positions[at],Math.fround(mapped[at%3]*physiqueScale[at%3]),'Every coordinate uses the shared position field');
 if(at%3===1)assert.equal(fuller.positions[at],sourceMesh.positions[at],'Exact Y correspondence');
}
assert.deepEqual(vertex(fuller.positions,0),vertex(fuller.positions,4),'Duplicate seam vertices remain coincident');
const h=1e-6;
function numericJacobian(point){
 const result=Array(9).fill(0);
 for(let axis=0;axis<3;axis++){
  const plus=[...point],minus=[...point];plus[axis]+=h;minus[axis]-=h;
  const p=balancePoint(...plus).position,m=balancePoint(...minus).position;
  for(let row=0;row<3;row++)result[row*3+axis]=(p[row]-m[row])/(2*h);
 }
 return result;
}
const transformVector=(j,t)=>[0,1,2].map(row=>physiqueScale[row]*dot(j.slice(row*3,row*3+3),t));
for(let i=0;i<5;i++){
 const point=vertex(sourceMesh.positions,i),j=numericJacobian(point),normal=vertex(fuller.normals,i);
 const tangent1=cross(unitNormal,[1,0,0]),tangent2=cross(unitNormal,tangent1);
 assert.ok(Math.abs(dot(normal,transformVector(j,tangent1)))<1e-7&&Math.abs(dot(normal,transformVector(j,tangent2)))<1e-7,'Inverse-Jacobian normals are perpendicular to independently differentiated tangents');
 assert.ok(Math.abs(Math.hypot(...normal)-1)<1e-7,'Transformed normals are unit length');
}
// Cover transition boundaries as well as their interiors, including the X=0
// reflection plane. ||J-I||_F bounds every singular value's distance from 1.
const heights=[.04,.12,.18,.23,.24,.29,.37,.44,.57,.58,.71,.72];
let largestDistortion=0;
for(const y of [...heights,...Array.from({length:101},(_,i)=>i/100)])for(let k=0;k<=65;k++)for(const z of [-.2,.2]){
 const x=k/100,{position,jacobian:j}=balancePoint(x,y,z),numerical=numericJacobian([x,y,z]);
 for(let at=0;at<9;at++)assert.ok(Math.abs(j[at]-numerical[at])<2e-8,'Analytic Jacobian matches independent central differences');
 const reflected=balancePoint(-x,y,z).position;
 assert.deepEqual(reflected.map((v,i)=>i===0?(-v||0):v),position,'Exact bilateral field symmetry');
 const distortion=Math.hypot(...j.map((v,i)=>v-(i%4===0?1:0)));largestDistortion=Math.max(largestDistortion,distortion);
 assert.ok(j[0]*j[8]>0&&distortion<.4,'Positive orientation and bounded local distortion');
 if(y>=.72)assert.deepEqual(position,[x,y,z],'Head and upper neck retain accepted proportions');
}
for(const point of [[.2,-.5,.1],[.5,.08,-.1],[.1,.02,.15],[.07,.75,.05]])assert.deepEqual(balancePoint(...point).position,point,'Legs, hands, pelvis and head stay at accepted fullness');
const chest=balancePoint(.12,.5,.12).position,waist=balancePoint(.16,.2,.08).position;
assert.ok(chest[0]>.12&&chest[2]>.12&&waist[0]<.16,'Restrained chest gain and waist taper');
assert.equal(waist[2],.08,'Waist depth stays intact');
for(let axis=0;axis<3;axis++){
 const coordinates=Array.from({length:5},(_,i)=>fuller.positions[i*3+axis]);
 assert.equal(fuller.bounds[0][axis],Math.min(...coordinates));assert.equal(fuller.bounds[1][axis],Math.max(...coordinates));
}
assert.equal(fuller.radius,Math.max(...Array.from({length:5},(_,i)=>Math.hypot(fuller.positions[i*3],fuller.positions[i*3+2]))));
for(const aspect of [128/212,512/640])for(let degree=0;degree<360;degree++){
 const yaw=degree*Math.PI/180,c=Math.cos(yaw),s=Math.sin(yaw),fit=bodyFit(fuller,aspect);
 for(let i=0;i<5;i++){
  const [x,y,z]=vertex(fuller.positions,i),viewX=c*x+s*z,viewZ=-s*x+c*z;
  assert.ok(Math.abs(viewX*fit/aspect)<=.9600001&&Math.abs(y*fit)<=.9600001,'All-angle large/card framing keeps its margin');
  assert.ok(Math.abs(viewZ/fuller.radius)<=1.0000001,'Geometry and normalized depth stay inside the same clip range');
 }
}
console.log('Physique PASS: unchanged source arrays/topology/UVs/seams, symmetric smooth balance, independent Jacobian/normal checks, positive orientation, exact bounds and all-angle framing; max sampled balance distortion',largestDistortion.toFixed(6));
// Female-source mode adds framing only. Every geometry array is retained.
const retained=retainSourceMesh(sourceMesh);
assert.deepEqual(sourceMesh,originalMesh);assert.deepEqual(retainSourceMesh(sourceMesh),retained);
for(const name of ['positions','normals','indices','uv','regions','manifest','masks'])assert.equal(retained[name],sourceMesh[name],name+' stays byte-exact');
for(let axis=0;axis<3;axis++){
 const values=Array.from({length:5},(_,i)=>sourceMesh.positions[i*3+axis]);
 assert.equal(retained.bounds[0][axis],Math.min(...values));assert.equal(retained.bounds[1][axis],Math.max(...values));
}
assert.equal(retained.radius,Math.max(...Array.from({length:5},(_,i)=>Math.hypot(sourceMesh.positions[i*3],sourceMesh.positions[i*3+2]))));
for(const aspect of [128/212,512/640]){
 const fit=bodyFit(retained,aspect);
 assert.ok(retained.radius*fit/aspect<=.9600001&&retained.halfHeight*fit<=.9600001,'Source bounds fit every yaw without changing proportions');
}
assert.equal(createHash('sha256').update(read('geometry.js')).digest('hex'),'bd1b695e5b76717edffc55992fb4d46bb6971ec9179e6b0bf2d17381ad833b3b','Approved male helper stays byte-exact');
assert.match(read('renderer.js').toString(),/return posedMesh\(data\)/,'Every rendered view uses the same derived pose');
assert.ok(!/fullerMesh|balancePoint/.test(read('renderer.js').toString()),'Renderer bypasses male physique fields');
assert.ok(!/muscles|score|theme|physiqueScale|balancePoint/.test(read('source-geometry.js').toString()),'Source geometry is theme/workload independent');
console.log('Female source PASS: exact positions/normals/topology/UV identity; metadata-only framing; unchanged male helper.');
assert.ok(!/muscles|score|theme|physiqueScale|balancePoint/.test(read('pose-geometry.js').toString()),'Pose is theme/workload independent');
for(const name of ['workload.js','assets/body_workload_cases.json','assets/SpaceMono-Regular.ttf','assets/SpaceMono-OFL.txt','assets/SpaceGrotesk-Variable.ttf','assets/SpaceGrotesk-OFL.txt'])assert.deepEqual(read(name),fs.readFileSync(path.resolve(root,'../body-3d-study',name)),`Approved source byte identity: ${name}`);
const fixtures=JSON.parse(read('assets/body_workload_cases.json'));assert.equal(fixtures.cases.length,12);assert.deepEqual(fixtures.canonicalMuscles,canonicalMuscles);
for(const fixture of fixtures.cases){const before=JSON.stringify(fixture);assert.deepEqual(calculateWorkload(fixture),fixture.expected,fixture.id);assert.equal(JSON.stringify(fixture),before);}
const live=structuredClone(fixtures.cases.find(c=>c.id==='active-before-first-set')),pending=live.exercises.find(e=>e.muscleGroup==='chest').sets.find(s=>!s.completed&&!s.deleted&&!s.isWarmup);
pending.completed=true;assert.equal(calculateWorkload(live).muscles.chest.count,1);const undo=structuredClone(live);pending.deleted=true;assert.equal(calculateWorkload(live).muscles.chest.count,0);assert.equal(calculateWorkload(undo).muscles.chest.count,1);pending.deleted=false;pending.isWarmup=true;assert.equal(calculateWorkload(live).muscles.chest.count,0);
assert.equal(glyphAlphabet.length,49);
const histogram=new Set(),inkMeans=[];
for(const shade of [41,75,110,145,180,215,255]){
 let ink=0;for(let row=0;row<64;row++)for(let col=0;col<64;col++){
  const glyph=materialGlyph(shade,col,row,{coverage:1,gx:0,gy:0});histogram.add(glyph);assert.notEqual(glyph,' ');ink+=glyphInk[glyph];
 }
 inkMeans.push(ink/4096);
}
for(const glyph of histogram)assert.ok(glyphAlphabet.includes(glyph),'Material stays inside the approved family');
assert.ok(histogram.size<glyphAlphabet.length/2,'Tonal roles use a restrained subset, not the full alphabet');
for(let i=1;i<inkMeans.length;i++)assert.ok(inkMeans[i]>inkMeans[i-1],'Geometry light increases measured glyph coverage');
assert.ok(inkMeans.at(-1)>4*inkMeans[0],'Source planes retain a meaningful ink-density range');
for(const theme of ['dark','light'])for(const compact of [false,true]){
 const alphas=[41,75,110,145,180,215,255].map(shade=>materialAlpha(shade,theme,1,compact));
 assert.ok(alphas.every(a=>a>0&&a<=1));
 assert.ok(alphas.at(-1)>alphas[0]+.15,'Geometry retains an opacity range in '+theme);
 for(let i=1;i<alphas.length;i++)assert.ok(alphas[i]>alphas[i-1]);
}
assert.notEqual(materialGlyph(62,7,8,{coverage:1,gx:0,gy:0}),materialGlyph(239,7,8,{coverage:1,gx:0,gy:0}));
// Exercise actual geometry sampling with synthetic surface buffers. No mesh or
// source-specific mapping is involved. A plane must not acquire false seams.
function surface(depthAt=()=>128,lightAt=()=>180){
 const pixels=new Uint8Array(21*21*4);
 for(let y=0;y<21;y++)for(let x=0;x<21;x++)pixels.set([lightAt(x,y),1,depthAt(x,y),255],(y*21+x)*4);
 return pixels;
}
const sample=pixels=>sampleSurfaceCell(pixels,21,21,3,3);
assert.equal(sample(new Uint8Array(21*21*4)),null,'Background adds no glyph');
// Behavior of the actual display transfer and cell sampler: shadows remain
// present, highlights retain headroom, and nearby planes never reverse order.
const shadowLight=shapePlaneLight(41),highlightLight=shapePlaneLight(255);
assert.ok(shadowLight>50&&shadowLight<75,'Unlit planes stay above the sparse punctuation floor');
assert.ok(highlightLight>225&&highlightLight<245,'Bright planes keep highlight headroom');
assert.ok(highlightLight-shadowLight>170,'Broad anatomy retains a useful tonal range');
for(let shade=42;shade<=255;shade++){
 const step=shapePlaneLight(shade)-shapePlaneLight(shade-1);
 assert.ok(step>0&&step<1.1,'Continuous light transfer preserves ordering without a hard knee');
}
assert.ok(shapePlaneLight(245)-shapePlaneLight(225)<shapePlaneLight(110)-shapePlaneLight(90),'Highlight transitions roll off more softly than low planes');
const plane=surface(),planeShade=sample(plane).shade;
assert.equal(planeShade,Math.round(shapePlaneLight(180)),'Transfer is applied to integrated surface light');
assert.equal(sample(surface((x)=>128+x-10)).shade,planeShade,'A sloping plane stays a plane');
assert.equal(sample(surface((x,y)=>128-Math.abs(x-10)-Math.abs(y-10))).shade,planeShade,'Convex form adds no cavity');
const recess=sample(surface((x,y)=>128+Math.min(12,Math.abs(x-10)+Math.abs(y-10))));
assert.ok(recess.shade<planeShade&&recess.shade>=planeShade-20,'A real recess gains subordinate, bounded contrast');
for(const compact of [false,true])for(const light of [41,75,145,215,255]){
 const broad=sampleSurfaceCell(surface(()=>128,()=>light),21,21,3,3,compact).shade;
 const recessed=sampleSurfaceCell(surface((x,y)=>x===10&&y===10?128:140,()=>light),21,21,3,3,compact).shade;
 assert.ok(recessed>41&&recessed<broad&&recessed>=broad-20,'Even deep source recesses retain shadow detail at both optical sizes');
}
assert.equal(sample(surface(x=>x<10?80:128)).shade,planeShade,'Depth discontinuity adds no outline');
const edge=surface();for(let y=0;y<21;y++)for(let x=0;x<21;x++)if(Math.abs(x-10)>1||Math.abs(y-10)>1)edge[(y*21+x)*4+3]=0;
assert.equal(sample(edge).shade,planeShade,'Missing neighboring surface adds no halo');
assert.equal(sample(surface(()=>128,(x,y)=>x===10&&y===10?90:180)).shade,Math.round(shapePlaneLight(170)),'Cell tone integrates its visible surface before display shaping');
const changedRegions=plane.slice();for(let at=1;at<changedRegions.length;at+=4)changedRegions[at]=8;
assert.equal(sample(changedRegions).shade,sample(plane).shade,'Region identity never changes tone');
const thin=new Uint8Array(21*21*4);thin.set([180,4,128,255],(11*21+9)*4);
const thinCell=sample(thin);assert.equal(thinCell.region,4);assert.equal(thinCell.coverage,1/9);
assert.ok(glyphAlphabet.includes(materialGlyph(thinCell.shade,3,3,thinCell)),'Thin occupied edges survive');
assert.equal(materialGlyph(180,0,0,{coverage:0,gx:0,gy:0}),' ');
for(const [gx,gy,glyph] of [[1,0,'|'],[0,1,'-'],[1,1,'/'],[1,-1,'\\']])assert.equal(materialGlyph(180,0,0,{coverage:1/3,gx,gy}),glyph);
// Sampling and painting share the exact fixed column phase. A shifted cell
// must read the source at its shifted position, including the UV region ID.
for(const phase of [-1,0,1]){
 const shifted=surface();const at=((10-phase)*21+10)*4;shifted[at+1]=7;
 assert.equal(sampleSurfaceCell(shifted,21,21,3,3,false,phase).region,7);
}
for(let col=0;col<100;col++)assert.ok([-1,0,1].includes(columnPhase(col)));
for(const theme of ['dark','light'])for(const compact of [false,true]){
 assert.equal(glyphCoverage(0,theme,compact),0,'No ink grows into transparent pixels');
 assert.equal(glyphCoverage(1,theme,compact),1);
 let previous=0;for(const alpha of [.1,.25,.5,.75,1]){
  const ink=glyphCoverage(alpha,theme,compact);assert.ok(ink>=alpha&&ink>previous&&ink<=1);previous=ink;
 }
}
assert.ok(glyphCoverage(.25,'light',true)>glyphCoverage(.25,'dark',true),'Light card calibrates fractional ink coverage');
// Execute the production atlas builder with synthetic Canvas ink metrics.
// This checks fitted geometry, not raster quality (the browser review owns it).
// The tall slash also exercises contour containment independently of cap fit.
for(const [width,height,pitch] of [[128,212,1.6],[512,640,3.2]])for(const dpr of [1,2]){
 const cols=Math.round(width/pitch),rows=Math.round(height/(pitch/.85));
 const cellW=width*dpr/cols,cellH=height*dpr/rows;
 let referenceSizes;
 for(const theme of ['dark','light'])for(const muscles of [{},{chest:{score:1}}]){
  const painted=[];
  const metrics=glyph=>({actualBoundingBoxLeft:0,actualBoundingBoxRight:60,
   actualBoundingBoxAscent:glyph==='/'?90:70,actualBoundingBoxDescent:0});
  const context=()=>({measureText:metrics,scale(){},drawImage(){},putImageData(){},
   getImageData:()=>({data:new Uint8ClampedArray(4)}),
   fillText(glyph,x,y){painted.push({glyph,x,y,size:parseFloat(this.font.slice(4))});}});
  const canvas=()=>({getContext:()=>context()});
  const atlas={canvas:{width:width*dpr,height:height*dpr},cols,rows,compact:pitch<2,
   atlas:canvas(),mesh:{manifest:{regions:[null,'chest']}}};
  globalThis.document={createElement:canvas};
  try{VolumeRenderer.prototype.buildAtlas.call(atlas,muscles,theme);}finally{delete globalThis.document;}
  assert.equal(painted.length,glyphAlphabet.length*2,'Every region retains every glyph, including contours');
  for(const [i,glyph] of painted.entries()){
   const inkW=.6*glyph.size,inkH=(glyph.glyph==='/'?.9:.7)*glyph.size;
   const baselineSize=Math.min(.94*cellW/.6,.94*cellH/(glyph.glyph==='/'?.9:.7));
   const areaRatio=(glyph.size/baselineSize)**2;
   assert.ok(areaRatio>=.88&&areaRatio<=.92,'A modest 8–12% nominal ink-area reduction at both optical sizes');
   assert.ok(inkW<cellW*.92&&inkH<cellH*.92,'Visible ink has breathing room within its cell');
   assert.ok(Math.abs(glyph.x+inkW/2-((i%glyphAlphabet.length)+.5)*atlas.tileW)<1e-10,'Ink remains horizontally centered');
   assert.ok(Math.abs(glyph.y-inkH/2-(Math.floor(i/glyphAlphabet.length)+.5)*atlas.tileH)<1e-10,'Ink remains vertically centered');
  }
  const sizes=painted.map(glyph=>glyph.size);
  if(referenceSizes)assert.deepEqual(sizes,referenceSizes,'Theme and workload cannot alter glyph spacing');
  else referenceSizes=sizes;
 }
}
console.log('Atlas fit PASS: modest area reduction, centered complete glyph family, theme/workload independence at large/card sizes and DPR 1/2.');
console.log('Measured source-tone glyph coverage:',inkMeans.map(n=>n.toFixed(4)).join(', '));
for(const theme of ['dark','light']){assert.equal(regionColor(null,{chest:{score:1}},theme),regionColor(null,{},theme));assert.notEqual(regionColor('chest',{chest:{score:1}},theme),regionColor('chest',{},theme));}
assert.equal(TURN_MS,52000);assert.ok(Math.abs(advanceYaw(0,52)-Math.PI*.002)<1e-12);
const state={yaw:0,ready:true,failed:false,paused:false,reduced:false,hidden:false,visible:true};assert.equal(canAnimate(state),true);
for(const [key,value] of [['ready',false],['failed',true],['paused',true],['reduced',true],['hidden',true],['visible',false]])assert.equal(canAnimate({...state,[key]:value}),false,key);
let next=0,draws=0;const queue=new Map();const loop=new MotionLoop(state,()=>draws++,{request:fn=>{queue.set(++next,fn);return next;},cancel:id=>queue.delete(id)});
function fire(time){assert.equal(queue.size,1);const [id,fn]=queue.entries().next().value;queue.delete(id);fn(time);}
loop.reconcile();loop.reconcile();assert.equal(queue.size,1,'Never duplicate a frame');fire(1000);assert.equal(state.yaw,0);fire(1052);assert.ok(Math.abs(state.yaw-Math.PI*.002)<1e-12);
for(const [key,value] of [['paused',true],['hidden',true],['visible',false],['reduced',true],['failed',true],['ready',false]]){
 const previous=state[key],yaw=state.yaw;state[key]=value;loop.reconcile();assert.equal(queue.size,0,key+' cancels');assert.equal(loop.previous,null);state[key]=previous;loop.reconcile();fire(1000000);assert.equal(state.yaw,yaw,key+' resumes without elapsed jump');fire(1000052);
}
loop.stop();assert.equal(queue.size,0);assert.ok(draws>0);
// Browser native frame APIs reject a custom object receiver. Exercise the
// production default wrappers, not only the injected deterministic scheduler.
let requested=0,cancelled=0;
globalThis.requestAnimationFrame=function(callback){assert.equal(this,undefined,'Global request must not receive the MotionLoop object');assert.equal(typeof callback,'function');requested++;return 73;};
globalThis.cancelAnimationFrame=function(handle){assert.equal(this,undefined,'Global cancel must not receive the MotionLoop object');assert.equal(handle,73);cancelled++;};
const nativeDefaults=new MotionLoop(state,()=>{});nativeDefaults.reconcile();nativeDefaults.stop();assert.equal(requested,1);assert.equal(cancelled,1);delete globalThis.requestAnimationFrame;delete globalThis.cancelAnimationFrame;

const renderer=read('renderer.js').toString();assert.match(renderer,/gl\.enable\(gl\.DEPTH_TEST\)/);assert.match(renderer,/gl\.drawElements/);assert.match(renderer,/sourceUV/);assert.ok(!/Math\.random|score.*shade|score.*glyph/.test(renderer));
const material=read('material.js').toString().split('export const colors')[0];assert.ok(!/muscles|score/.test(material),'Character selection never reads workout values');
for(const name of ['renderer.js','geometry.js','source-geometry.js','pose-geometry.js','study.js','workload.js','motion.js','material.js']){const check=spawnSync(process.execPath,['--check',path.join(root,name)],{encoding:'utf8'});assert.equal(check.status,0,check.stderr);assert.ok(!/https?:\/\//.test(read(name).toString()),'Local runtime '+name);}
const html=read('index.html').toString(),css=read('study.css').toString(),study=read('study.js').toString();assert.match(html,/Female source study/);assert.match(css,/touch-action:pan-y/);assert.match(css,/min-height:48px/);assert.match(study,/prefers-reduced-motion/);assert.match(study,/IntersectionObserver/);assert.match(study,/visibilitychange/);assert.match(study,/pointercancel/);assert.match(html,/id="retry"/);assert.match(study,/Body preview unavailable · retry below/);assert.match(study,/compact-view'\)\.textContent='Unavailable'/);
// Execute the actual label refresh function with a small DOM stand-in. A
// preference change after failure must not advertise a working/rotating body.
const labelNodes=Object.fromEntries(['motion','motion-state','compact-view'].map(id=>[id,{}]));
const labelState={failed:true,ready:false,paused:false,reduced:false,view:'front'};
const labelSource=study.slice(study.indexOf('function motionLabels('),study.indexOf('function failArtwork('));
const labelContext={state:labelState,$:id=>labelNodes[id],document:{querySelectorAll:()=>[]}};
for(const reduced of [false,true,false]){
 labelState.reduced=reduced;runInNewContext(labelSource+';motionLabels();',labelContext);
 assert.equal(labelNodes.motion.disabled,true);assert.equal(labelNodes.motion.textContent,'Rotation off');
 assert.equal(labelNodes['motion-state'].textContent,'Body preview unavailable · retry below');assert.equal(labelNodes['compact-view'].textContent,'Unavailable');
}
labelState.failed=false;labelState.ready=true;runInNewContext(labelSource+';motionLabels();',labelContext);
assert.equal(labelNodes.motion.disabled,false);assert.equal(labelNodes['motion-state'].textContent,'Rotating · one turn in 52 seconds');
console.log('PASS: 12 byte-identical shared goldens; real set completion/removal/undo; calibrated glyph subset and geometry sampling; monotonic light shoulder, highlight headroom and readable bounded recesses; color-only data; one-frame lifecycle, all stop gates and no elapsed jump; failed-state preference label refresh; local assets and JS syntax.');
