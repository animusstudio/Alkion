import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {webcrypto} from 'node:crypto';
import {runInNewContext} from 'node:vm';
import {validateDisplay,validatePick,regions,protocolVersion,maxPitch} from '../assets/character_body/protocol.js';
import {loadMesh,pickSurfaceRegion,VolumeRenderer,orbitFrame} from '../assets/character_body/renderer.js';
import {fullerMesh} from '../assets/character_body/geometry.js';
import {posedMesh} from '../assets/character_body/pose-geometry.js';
import {surfaceRegions,surfaceProjectionRevision,regionProjectionGLSL} from '../assets/character_body/regions.js';
import {MotionLoop} from '../assets/character_body/motion.js';

assert.equal(protocolVersion,5);assert.equal(maxPitch,Math.PI/4);
const display={version:5,style:'male',scores:Object.fromEntries(regions.map(k=>[k,0])),neutral:[240,240,245],accent:[255,104,53],background:[12,12,14],theme:'dark',visible:true,reduced:false,compact:true,paused:true,yaw:0,turn:0,command:0,revision:0,retry:0};
assert.equal(validateDisplay(display),display);
assert.deepEqual(surfaceRegions.filter(Boolean),regions);
assert.equal(regions.length,13);assert.equal(surfaceRegions[12],'adductors');assert.equal(surfaceRegions[13],'abductors');
assert.equal(surfaceProjectionRevision,'alkion-surface-3');
// Each code-defined field writes its own atlas row; hip fields yield to painted masks.
for(const id of [9,10,11,12,13])assert.ok(regionProjectionGLSL.includes(`return ${id}.0/255.0`),`projected row ${id}`);
assert.ok(regionProjectionGLSL.indexOf('return 11.0/255.0')<regionProjectionGLSL.indexOf('if(original>.5/255.0)return original;'));
assert.ok(regionProjectionGLSL.indexOf('if(original>.5/255.0)return original;')<regionProjectionGLSL.indexOf('return 13.0/255.0'));
// Static cross-language contract parity complements (but does not execute) the
// Android guard. Native queue behavior is exercised by its separate JVM check.
const native=readFileSync(new URL('../android/app/src/main/kotlin/dev/animusstudio/alkion/CharacterBodyView.kt',import.meta.url),'utf8');
const nativeKeys=[...native.match(/val muscles = setOf\(([^)]+)\)/)[1].matchAll(/"([a-z]+)"/g)].map(m=>m[1]);
assert.deepEqual(nativeKeys,regions);assert.match(native,/map\["version"\] != BodyPickGuard\.VERSION/);assert.ok(native.includes('BodyPickGuard.view(view)'));
assert.ok(native.includes('"regions.js"'));assert.ok(!/"version" to [23]\b|"version"\) != [23]\b/.test(native));
assert.ok(native.includes('if (BuildConfig.DEBUG || BuildConfig.BODY_TIMING) Log.i(')&&!/[^|] Log\.i\("AlkionBody"/.test(native.replace('if (BuildConfig.DEBUG || BuildConfig.BODY_TIMING) Log.i("AlkionBody"','')),'Body timing logs only in debug or the explicit timing build');
const gradle=readFileSync(new URL('../android/app/build.gradle.kts',import.meta.url),'utf8');
assert.match(gradle,/buildConfigField\("boolean", "BODY_TIMING", \(privateCatalogDev &&\s+providers\.environmentVariable\("ALKION_BODY_TIMING"\)\.orNull == "1"\)\.toString\(\)\)/);
const guard=readFileSync(new URL('../android/app/src/main/java/dev/animusstudio/alkion/BodyPickGuard.java',import.meta.url),'utf8');
assert.deepEqual([...guard.match(/REGIONS = Set\.of\(([^)]+)\)/)[1].matchAll(/"([a-z]+)"/g)].map(m=>m[1]).sort(),[...regions].sort());
assert.ok(guard.includes('static final int VERSION = 5;')&&guard.includes('Integer.valueOf(VERSION)')&&guard.includes('MAX_PITCH = Math.PI / 4')&&guard.includes('Set.of("zoom", "x", "y", "pitch")'));
const dart=readFileSync(new URL('../lib/ui/character_body.dart',import.meta.url),'utf8');
assert.ok(dart.includes('const _protocol = 5;')&&dart.includes("'version': _protocol")&&dart.includes("event['version'] != _protocol")&&!/'version': [34]\b/.test(dart));
assert.ok(dart.includes("'pitch': widget.controller.pitch")&&dart.includes('static const maxPitch = math.pi / 4;'));
const figure=readFileSync(new URL('../lib/ui/body_figure.dart',import.meta.url),'utf8');
assert.ok(figure.includes(`bodySurfaceProjectionRevision = '${surfaceProjectionRevision}'`));

const coarse=JSON.parse(readFileSync(new URL('../test/fixtures/body_workload_cases.json',import.meta.url)));
assert.equal(coarse.version,2);assert.equal(coarse.projection,'legacy-coarse');assert.deepEqual(coarse.canonicalMuscles,regions);
const countScore=n=>n<=0?0:n===1?.2:n<=3?.4:n<=6?.6:n<=10?.8:1;
for(const example of coarse.cases)if(example.expected.availability==='ready')for(const {count,score} of Object.values(example.expected.muscles))assert.equal(score,countScore(count));
for(const size of [8,11])assert.throws(()=>validateDisplay({...display,scores:Object.fromEntries(regions.slice(0,size).map(k=>[k,0]))}));
for(const patch of [{version:1},{version:2},{version:3},{version:4},{version:6},{turn:NaN},{turn:-1},{turn:Math.PI*2},{revision:-1},{revision:.1},{revision:Number.MAX_SAFE_INTEGER+1},{style:'../outside'},{yaw:NaN},{yaw:Math.PI*2},{command:-1},{retry:.1},{neutral:[256,0,0]},{visible:1},{scores:{...display.scores,chest:Infinity}},{scores:{...display.scores,alien:0}},{records:[]}])assert.throws(()=>validateDisplay({...display,...patch}));

// Production loader: exact style dispatch, same-origin paths, hash failure.
const positions=new Float32Array([-.5,-1,-.2,.5,.6,.1,-.2,1,.3]);
const normals=new Float32Array([0,1,0,0,1,0,0,1,0]);
const uv=new Float32Array([0,0,1,0,0,1]),indices=new Uint32Array([0,1,2]);
const bytes=new Uint8Array(positions.byteLength+normals.byteLength+uv.byteLength+indices.byteLength);
let offset=0;const attributes={};
for(const [key,value,type] of [['positions',positions,'<f4'],['normals',normals,'<f4'],['uv',uv,'<f4'],['indices',indices,'<u4']]){bytes.set(new Uint8Array(value.buffer),offset);attributes[key]={type,count:value.length,byteOffset:offset};offset+=value.byteLength;}
const sha256=Buffer.from(await webcrypto.subtle.digest('SHA-256',bytes)).toString('hex');
const manifest={version:1,binary:'body.mesh.bin',sha256,vertices:3,triangles:1,attributes};
let corrupt=false;const urls=[];
globalThis.Image=class{decode(){return Promise.resolve();}};
globalThis.fetch=async url=>{urls.push(url);return {ok:true,json:async()=>manifest,arrayBuffer:async()=>{const result=bytes.slice();if(corrupt)result[0]^=1;return result.buffer;}};};
for(const style of ['male','female']){
 const actual=await loadMesh(style),expected=(style==='male'?fullerMesh:posedMesh)({positions,normals,uv,indices,manifest});
 assert.deepEqual(actual.positions,expected.positions);assert.deepEqual(actual.normals,expected.normals);
 assert.equal(actual.masks.src,`models/${style}/regions.png`);
}
assert.deepEqual(urls,['models/male/body.mesh.json','models/male/body.mesh.bin','models/female/body.mesh.json','models/female/body.mesh.bin']);
corrupt=true;await assert.rejects(loadMesh('male'),/integrity/);await assert.rejects(loadMesh('invalid'),/style/);
globalThis.fetch=async()=>({ok:false,status:404});await assert.rejects(loadMesh('male'),/art_unavailable/);

// Exercise the actual atlas builder with the production converter's null row.
// Capture ink per row rather than testing a stand-in selection predicate.
const inkRows=[];
const ink={scale(){},fillText(){inkRows.push(this.fillStyle);}};
const atlasContext={measureText:()=>({actualBoundingBoxLeft:0,actualBoundingBoxRight:70,actualBoundingBoxAscent:70,actualBoundingBoxDescent:0}),drawImage(){},getImageData:()=>({data:new Uint8ClampedArray(4)}),putImageData(){}};
globalThis.document={createElement:()=>({getContext:()=>ink})};
const atlas={mesh:{manifest:{regions:[null,...regions]}},canvas:{width:100},cols:10,rows:20,atlas:{getContext:()=>atlasContext},compact:false};
for(const selected of [null,...regions]){
 inkRows.length=0;atlas.atlasKey='';
 VolumeRenderer.prototype.buildAtlas.call(atlas,Object.fromEntries(regions.map(key=>[key,{score:0}])),'dark',selected);
 const rowSize=inkRows.length/(regions.length+1);
 const accent='rgb(255,104,53)';
 for(let row=0;row<=regions.length;row++)assert.equal(inkRows[row*rowSize]===accent,row>0&&regions[row-1]===selected,`atlas row ${row}, selection ${selected}`);
}
console.log('PASS: actual null-neutral atlas remains neutral; each mapped selection accents only its own row');

// Exercise the production runtime with fake graphics and a controlled RAF clock.
// Counts cover all renderer draws, not just outstanding animation callbacks.
const events=[],raf=new Map(),listeners={},documentListeners={};let lastView,counter=0,draws=0,disposals=0,loadCount=0,failLoad=false,now=100,lastYaw=0,bufferResets=0,clears=0;
const canvas={getContext:()=>({clearRect(){clears++;}}),addEventListener:(name,cb)=>listeners[name]=cb};
const window={AlkionNative:{postMessage:json=>events.push(JSON.parse(json))},addEventListener(){}};
const document={getElementById:()=>canvas,fonts:{load:async()=>[{}]},addEventListener:(name,cb)=>documentListeners[name]=cb,hidden:false};
const runtime=readFileSync(new URL('../assets/character_body/runtime.js',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
let resized;
runInNewContext(runtime,{
 window,document,performance:{now:()=>now},AbortController,
 ResizeObserver:class{constructor(callback){resized=callback;}observe(){}},
 MotionLoop:class extends MotionLoop{constructor(state,draw){super(state,draw,{request:cb=>{const id=++counter;raf.set(id,cb);return id;},cancel:id=>raf.delete(id)});}},
 VolumeRenderer:class{constructor(_canvas,_mesh,compact){this.compact=compact;}set pixels(value){if(value===null)bufferResets++;}pick(){return 'chest';}draw(yaw,_muscles,_theme,_mode,_selected,view){draws++;lastYaw=yaw;lastView=view;}dispose(){disposals++;}},
 loadMesh:async()=>{loadCount++;if(failLoad)throw new Error('art_unavailable');return {};},colors:{},validateDisplay,validatePick,protocolVersion,regions,
});
const flush=()=>new Promise(resolve=>setImmediate(resolve));
const frame=(time=now+16)=>{now=time;const callbacks=[...raf];raf.clear();for(const [,callback] of callbacks)callback(now);};
const near=(actual,expected)=>assert.ok(Math.abs(actual-expected)<1e-10,`${actual} != ${expected}`);
let current=display;
const update=patch=>window.AlkionBody.update(current={...current,...patch});
update({});await flush();assert.equal(draws,0);assert.equal(raf.size,1);frame();assert.equal(draws,1);assert.equal(raf.size,0);
assert.equal(events.at(-1).status,'ready');
let baseline=draws;
for(let i=1;i<=120;i++)update({turn:i*.01,yaw:i*.01});
assert.equal(draws,baseline);assert.equal(raf.size,1);frame();assert.equal(draws,baseline+1);near(lastYaw,1.2);
baseline=draws;for(let i=0;i<120;i++)update({});assert.equal(raf.size,0);assert.equal(draws,baseline);
// Rebuilds and resize invalidation share autoplay's single frame.
update({paused:false});for(let i=0;i<120;i++)update({});resized();resized();assert.equal(draws,baseline);assert.equal(raf.size,1);
frame(300);assert.equal(draws,baseline+1);frame(400);const autoplayYaw=lastYaw;assert.ok(autoplayYaw>1.2);
// First drag must use the current JS angle, ignoring a stale absolute yaw.
update({paused:true});assert.equal(raf.size,0);
update({turn:1.29,yaw:.09});frame();near(lastYaw,autoplayYaw+.09);
// Latest cumulative turn preserves skipped events, negative drag and wrapping.
update({turn:6.2});update({turn:.02});frame();near(lastYaw,(autoplayYaw+.09+.02-1.29+Math.PI*2)%(Math.PI*2));
update({command:1,yaw:Math.PI,turn:0});frame();near(lastYaw,Math.PI);
update({turn:Math.PI*2-.2});frame();near(lastYaw,Math.PI-.2);
update({command:2,yaw:0,turn:0,reduced:true,paused:false});frame();near(lastYaw,0);assert.equal(raf.size,0);
update({paused:true,turn:.3,yaw:.3,revision:123});frame(2000);near(lastYaw,.3);assert.equal(raf.size,0);
assert.equal(events.at(-1).revision,123);assert.equal(events.at(-1).turn,.3);
// Hidden changes retain only dirty state; no catch-up or stale scheduled draw.
update({visible:false});update({turn:.6});assert.equal(raf.size,0);baseline=draws;frame();assert.equal(draws,baseline);
update({visible:true,reduced:false,paused:false});assert.equal(raf.size,1);frame(5000);near(lastYaw,.6);
window.AlkionBody.hostPaused(true);assert.equal(raf.size,0);window.AlkionBody.hostPaused(false);assert.equal(raf.size,1);
document.hidden=true;documentListeners.visibilitychange();assert.equal(raf.size,0);
window.AlkionBody.hostPaused(false);assert.equal(raf.size,0,'Native displays cannot override document visibility');
document.hidden=false;documentListeners.visibilitychange();assert.equal(raf.size,1);
listeners.renderfailure();assert.equal(raf.size,0);assert.equal(events.at(-1).status,'error');
failLoad=true;update({retry:1});await flush();assert.equal(events.at(-1).status,'unavailable');
failLoad=false;update({retry:2,style:'female'});await flush();frame();assert.equal(events.at(-1).status,'ready');assert.equal(loadCount,3);
update({paused:true,interaction:{enabled:true,selected:null,generation:7}});frame();
const token=()=>Object.fromEntries(['generation','frame','load','layout'].map(key=>[key,events.findLast(event=>event.status==='ready')[key]]));
const pick=(patch={})=>window.AlkionBody.pick({version:5,id:42,x:.5,y:.5,...token(),...patch});
pick();assert.equal(events.at(-1).region,'chest');
pick({frame:0});assert.equal(events.at(-1).region,null);
const beforeZoom=token();update({view:{zoom:3,x:.5,y:-.4,pitch:0}});pick(beforeZoom);assert.equal(events.at(-1).region,null,'Zoom/pan invalidates old pixels');frame();pick();assert.equal(events.at(-1).region,'chest');
// Tilt is view state: the next frame draws it, and older pixels cannot answer.
const beforeTilt=token();update({view:{zoom:3,x:.5,y:-.4,pitch:-maxPitch}});pick(beforeTilt);assert.equal(events.at(-1).region,null,'Tilt invalidates old pixels');
frame();assert.equal(lastView.pitch,-maxPitch);pick();assert.equal(events.at(-1).region,'chest','A pick reads the tilted frame it names');
assert.equal(events.findLast(event=>event.status==='ready').version,5);
{const before=events.length;pick({version:4});assert.equal(events.length,before,'A v4 pick is never answered');}
// Field-by-field display comparison: every visual input still retires old pixels.
for(const patch of [{neutral:[1,2,3]},{accent:[9,9,9]},{scores:{...display.scores,chest:.4}},{theme:'light'},{interaction:{enabled:true,selected:'back',generation:7}},{view:{zoom:3,x:.5,y:-.4,pitch:.1}}]){
 const before=token();update(patch);pick(before);assert.equal(events.at(-1).region,null,`Stale after ${Object.keys(patch)[0]}`);frame();pick();assert.equal(events.at(-1).region,'chest',Object.keys(patch)[0]);
}
{const before=token(),n=events.length;update({});pick(before);assert.equal(events.at(-1).region,'chest','An identical display keeps the frame');assert.equal(events.length,n+1);}
const oldToken=token();update({turn:.9,interaction:{enabled:true,selected:null,generation:8}});
pick(oldToken);assert.equal(events.at(-1).region,null,'A pending rotation cannot pick old pixels');frame();
pick();assert.equal(events.at(-1).region,'chest');
resized();pick();assert.equal(events.at(-1).region,null,'Layout invalidation rejects retained pixels');frame();
window.AlkionBody.hostPaused(true);pick();assert.equal(events.at(-1).region,null);window.AlkionBody.hostPaused(false);frame();
update({interaction:{enabled:false,selected:null,generation:9}});frame();pick();assert.equal(events.at(-1).region,null);
// Style cache and native lease reuse do not re-prepare immutable models.
const cacheBaseline=loadCount;
update({style:'male'});await flush();frame();assert.equal(loadCount,cacheBaseline+1);
update({style:'female'});await flush();frame();assert.equal(loadCount,cacheBaseline+1);
const warmBufferResets=bufferResets,warmClears=clears;window.AlkionBody.hostPaused(true);window.AlkionBody.reset(1);assert.equal(clears,warmClears+1,'New lease clears stale workload pixels before another display');window.AlkionBody.hostPaused(false);
update({retry:0,command:0,yaw:0,turn:0,view:{zoom:1,x:0,y:0,pitch:0}});await flush();frame();assert.equal(loadCount,cacheBaseline+1,'Warm lease reuses prepared style and renderer');near(lastYaw,0);assert.equal(bufferResets,warmBufferResets,'Same-sized warm lease retains readback buffer and glyph atlas');
assert.equal(events.at(-1).lease,1);assert.equal(events.at(-1).cacheHit,1);
window.AlkionBody.hostPaused(true);const hiddenBaseline=loadCount;update({style:'male',retry:3});await flush();assert.equal(loadCount,hiddenBaseline,'No hidden model preparation');
window.AlkionBody.hostPaused(false);await flush();frame();assert.equal(loadCount,hiddenBaseline+1);
update({paused:true});resized();assert.equal(raf.size,1);window.AlkionBody.dispose();assert.equal(raf.size,0);baseline=draws;frame();assert.equal(draws,baseline);assert.ok(disposals>=2);
// Native drops a status over 1,024 characters: every report must fit, with
// the aggregate timing summary (numbers only, rounded) included.
assert.ok(events.some(event=>Number.isFinite(event.iP50)&&Number.isFinite(event.tMsgs)),'Timing summary reported');
for(const event of events)assert.ok(JSON.stringify(event).length<900,`Status report too long: ${JSON.stringify(event).length}`);
for(const event of events)for(const key of ['tFrames','tMsgs','iP50','iP90','iMax','dP50','dP90','glMs','readMs','composeMs'])if(key in event)assert.ok(Number.isFinite(event[key])&&event[key]>=0,key);
console.log('PASS: protocol v5, exact style dispatch, one latest draw/frame, no identical paused redraws, cumulative drag continuity, lifecycle/reduced motion/retry/disposal');

// Asynchronous readback: a frame's pick identity is published only after its
// pixels land, only for the latest drawn frame, and never after invalidation.
{
 const events=[],raf=new Map(),timers=[];let counter=0,ready=false,draws=0,pending=true;
 const window={AlkionNative:{postMessage:json=>events.push(JSON.parse(json))},addEventListener(){}};
 const canvas={getContext:()=>({clearRect(){}}),addEventListener(){}};
 const document={getElementById:()=>canvas,fonts:{load:async()=>[{}]},addEventListener(){},hidden:false};
 let resized;
 runInNewContext(runtime,{window,document,performance:{now:()=>0},AbortController,setTimeout:cb=>{timers.push(cb);return timers.length;},
  ResizeObserver:class{constructor(callback){resized=callback;}observe(){}},
  MotionLoop:class extends MotionLoop{constructor(state,draw){super(state,draw,{request:cb=>{const id=++counter;raf.set(id,cb);return id;},cancel:id=>raf.delete(id)});}},
  VolumeRenderer:class{pollReadback(){return ready;}readbackPending(){return pending;}finishReadback(){ready=true;return true;}pick(){return 'chest';}draw(){draws++;ready=false;}dispose(){}},
  loadMesh:async()=>({}),colors:{},validateDisplay,validatePick,protocolVersion,regions});
 const frame=()=>{const callbacks=[...raf];raf.clear();for(const [,callback] of callbacks)callback(16);};
 const runTimers=()=>{const pending=timers.splice(0);for(const cb of pending)cb();};
 const tokens=()=>events.filter(e=>e.status==='ready'&&Number.isInteger(e.frame)).map(e=>e.frame);
 let current={...display,interaction:{enabled:true,selected:null,generation:1}};
 const update=patch=>window.AlkionBody.update(current={...current,...patch});
 const pickAt=frame=>{const n=events.length;window.AlkionBody.pick({version:5,id:7,generation:1,frame,load:1,layout:0,x:.5,y:.5});return events.slice(n).find(e=>e.type==='pick')?.region??null;};
 update({});await flush();frame();assert.equal(draws,1);
 assert.deepEqual(tokens(),[],'No pick identity before the pixels land');assert.equal(pickAt(1),null);
 runTimers();assert.deepEqual(tokens(),[],'Still pending: no identity');
 ready=true;runTimers();assert.deepEqual(tokens(),[1]);assert.equal(pickAt(1),'chest');
 // Two draws before either copy lands: only the latest is ever published.
 update({turn:.1,yaw:.1});frame();assert.equal(pickAt(1),null,'A newer draw retires the old identity');
 update({turn:.2,yaw:.2});frame();ready=true;runTimers();assert.deepEqual(tokens(),[1,3],'Frame 2 never published');
 // An input change after the draw invalidates its pending copy.
 update({turn:.3,yaw:.3});frame();update({view:{zoom:2,x:0,y:0,pitch:.2}});ready=true;runTimers();
 assert.deepEqual(tokens(),[1,3],'Invalidated pending frame never published');frame();ready=true;runTimers();assert.deepEqual(tokens(),[1,3,5]);
 // Layout invalidation and a stalled copy: the copy is forced after ~250 polls.
 resized();frame();for(let i=0;i<260&&timers.length;i++)runTimers();assert.deepEqual(tokens(),[1,3,5,6],'A stalled copy completes');
 // A frame whose copy can never land (a resize retired its fence and no draw
 // followed): polling stops at once and exactly one redraw is requested, whose
 // landed copy publishes a pick frame again. No 4 ms poll repeats forever.
 pending=false;resized();frame();assert.equal(draws,7);runTimers();
 assert.equal(timers.length,0,'No poll is rescheduled without a pending copy');assert.equal(raf.size,1,'One redraw is requested');
 pending=true;frame();assert.equal(draws,8);ready=true;runTimers();assert.deepEqual(tokens(),[1,3,5,6,8],'The redraw publishes its frame');{const t=events.findLast(e=>e.status==='ready'&&e.frame===8),n=events.length;window.AlkionBody.pick({version:5,id:8,generation:t.generation,frame:8,load:t.load,layout:t.layout,x:.5,y:.5});assert.equal(events.slice(n).find(e=>e.type==='pick')?.region,'chest','The redrawn frame picks');}
 // The redraw is requested once: a second fence-less frame stops quietly.
 pending=false;resized();frame();runTimers();assert.equal(raf.size,1);frame();assert.equal(draws,10);runTimers();
 assert.equal(timers.length,0);assert.equal(raf.size,0,'At most one redraw per published frame');
 pending=true;resized();frame();ready=true;runTimers();assert.deepEqual(tokens(),[1,3,5,6,8,11],'Normal readback resumes');
 console.log('PASS: async readback publishes only the latest landed frame; invalidation, stalls and fence-less frames handled');
}

// Exact retained-pixel addressing (WebGL bottom-up), including neutral and
// background; no neighbour/hidden-region approximation is permitted.
const pixels=new Uint8Array(3*2*4),names=['neutral','chest','back','alien'];
const put=(x,y,id,alpha=255)=>{const at=((1-y)*3+x)*4;pixels[at+1]=id;pixels[at+3]=alpha;};
put(0,0,1);put(1,0,2);put(2,0,0);put(0,1,1,0);put(1,1,3);put(2,1,2);
assert.equal(pickSurfaceRegion(pixels,3,2,names,0,0),'chest');
assert.equal(pickSurfaceRegion(pixels,3,2,names,.5,.1),'back');
assert.equal(pickSurfaceRegion(pixels,3,2,names,.99,.99),'back');
for(const [x,y] of [[.99,0],[0,.8],[.5,.8],[1,0],[0,1],[-.01,0],[NaN,0],[0,Infinity]])assert.equal(pickSurfaceRegion(pixels,3,2,names,x,y),null);
const hip=new Uint8Array(2*1*4);hip[1]=12;hip[3]=255;hip[5]=13;hip[7]=255;
assert.equal(pickSurfaceRegion(hip,2,1,surfaceRegions,0,0),'adductors');
assert.equal(pickSurfaceRegion(hip,2,1,surfaceRegions,.5,0),'abductors');
hip[5]=14;assert.equal(pickSurfaceRegion(hip,2,1,surfaceRegions,.5,0),null,'Rows past the installed projection are unknown');
const request={version:5,id:1,generation:0,frame:1,load:1,layout:0,x:.5,y:.5};
assert.equal(validatePick(request),request);
for(const patch of [{id:-1},{generation:.5},{frame:NaN},{load:Infinity},{layout:1e20},{x:1},{y:-.1},{x:NaN},{region:'chest'},{version:2},{version:3},{version:4},{version:6}])assert.throws(()=>validatePick({...request,...patch}));
for(const patch of [{enabled:1},{selected:'alien'},{generation:-1},{selected:'chest',enabled:false}])assert.throws(()=>validateDisplay({...display,interaction:{enabled:true,selected:null,generation:0,...patch}}));
for(const selected of ['adductors','abductors'])assert.equal(validateDisplay({...display,interaction:{enabled:true,selected,generation:0}}).interaction.selected,selected);
console.log('PASS: exact top-left normalized surface picking, background/neutral/unknown rejection and bounded interaction protocol');

for(const view of [{zoom:0,x:0,y:0,pitch:0},{zoom:3.1,x:0,y:0,pitch:0},{zoom:1,x:.01,y:0,pitch:0},{zoom:3,x:1.1,y:0,pitch:0},{zoom:2,x:0,y:NaN,pitch:0},{zoom:2,x:0,y:0,pitch:0,other:1},
 // A version-4 view (no pitch) and every pitch outside ±45° are rejected.
 {zoom:3,x:1,y:-1},{zoom:1,x:0,y:0,pitch:Math.PI/4+1e-12},{zoom:1,x:0,y:0,pitch:-Math.PI/4-1e-12},{zoom:1,x:0,y:0,pitch:Math.PI/2},{zoom:1,x:0,y:0,pitch:NaN},{zoom:1,x:0,y:0,pitch:Infinity},{zoom:1,x:0,y:0,pitch:'0'},{zoom:1,x:0,y:0,pitch:null}])assert.throws(()=>validateDisplay({...display,view}),JSON.stringify(view));
assert.equal(validateDisplay({...display,view:{zoom:3,x:1,y:-1,pitch:0}}).view.zoom,3);
for(const pitch of [-Math.PI/4,-.3,0,.3,Math.PI/4])assert.equal(validateDisplay({...display,view:{zoom:1,x:0,y:0,pitch}}).view.pitch,pitch);

// Camera orbit: pitch 0 keeps the accepted depth scale exactly; any tilt keeps
// every vertex inside the depth range (no clipping) and the body's vertical
// centre fixed on screen. This mirrors the vertex shader's arithmetic.
const orbitMesh=fullerMesh({positions:new Float32Array([-.3,-1,-.25,.32,1,.2,0,.1,.3,.1,.62,-.28,-.2,-.6,.27]),normals:new Float32Array(15).fill(1/Math.sqrt(3)),uv:new Float32Array(10),indices:new Uint32Array([0,1,2,2,3,4]),manifest});
assert.equal(orbitFrame(orbitMesh,0).depthRange,orbitMesh.radius);assert.equal(orbitFrame(orbitMesh,0).extent,orbitMesh.halfHeight);
for(const pitch of [-maxPitch,-.1,.35,maxPitch]){const o=orbitFrame(orbitMesh,pitch);assert.ok(o.extent>=orbitMesh.halfHeight&&o.depthRange>=orbitMesh.radius,'A tilt never narrows the level frame');}assert.equal(orbitFrame(orbitMesh,0).cos,1);assert.equal(orbitFrame(orbitMesh,0).sin,0);
assert.deepEqual(orbitFrame(orbitMesh,9),orbitFrame(orbitMesh,maxPitch),'Renderer clamps a tilt it is given');
const orbitPoint=(x,y,z,yaw,o)=>{const c=Math.cos(yaw),s=Math.sin(yaw),qx=c*x+s*z,qy=y-o.centerY,qz=-s*x+c*z;return [qx,y+(o.cos-1)*qy-o.sin*qz,o.sin*qy+o.cos*qz];};
for(const pitch of [-maxPitch,-.4,0,.2,maxPitch]){
 const o=orbitFrame(orbitMesh,pitch);
 for(let yaw=0;yaw<Math.PI*2;yaw+=Math.PI/12)for(let at=0;at<orbitMesh.positions.length;at+=3){
  const [,y,z]=orbitPoint(orbitMesh.positions[at],orbitMesh.positions[at+1],orbitMesh.positions[at+2],yaw,o);
  assert.ok(Math.abs(z)<=o.depthRange+1e-9,`pitch ${pitch}: vertex depth ${z} past ${o.depthRange}`);
  assert.ok(Math.abs(y)<=o.extent+1e-9,`pitch ${pitch}: vertex height ${y} past the framed extent ${o.extent}`);
 }
 const [,cy]=orbitPoint(0,o.centerY,0,1.1,o);assert.ok(Math.abs(cy-o.centerY)<1e-12,'Orbit pivots on the vertical centre');
}
// Positive pitch raises the camera: the crown leans toward the viewer, a
// front-facing point drops down the screen.
{const o=orbitFrame(orbitMesh,maxPitch),[,,crown]=orbitPoint(0,orbitMesh.bounds[1][1],0,0,o),[,chestY]=orbitPoint(0,o.centerY,.3,0,o);assert.ok(crown>0&&chestY<o.centerY);}
console.log('PASS: protocol 5 view pitch bounds, v4 rejection, tilt invalidation and a bounded camera orbit around the vertical centre');

// GPU compose fallback: on a WebGL2 device whose composer fails to compile,
// link or complete its framebuffers, at setup or at a later resize, 'auto'
// mode falls back once to the CPU reference path on a fresh surface, which
// renders glyphs and picks. Explicit 'gpu' mode still fails. Fake graphics
// only: the real VolumeRenderer, material sampler and pick addressing run.
{
 const chest=surfaceRegions.indexOf('chest'),contexts=[],failures=[],savedDocument=globalThis.document;
 const glyphDraws={n:0};
 const fake2d=()=>({measureText:()=>({actualBoundingBoxLeft:0,actualBoundingBoxRight:70,actualBoundingBoxAscent:70,actualBoundingBoxDescent:0}),scale(){},fillText(){},clearRect(){},putImageData(){},
  drawImage(){glyphDraws.n++;},getImageData:(x,y,w,h)=>({data:new Uint8ClampedArray(Math.max(1,w*h)*4)})});
 const fill=dst=>{for(let at=0;at<dst.length;at+=4)dst.set([180,chest,128,255],at);};
 function fakeGL(kind,{failCompose,failFramebuffer}){
  const constants=new Map(),log={kind,lost:0,linkedComposer:false};let proxy;
  const gl={log,getExtension:name=>name==='WEBGL_lose_context'?{loseContext(){log.lost++;}}:{},
   createShader:()=>({}),shaderSource:(shader,source)=>{shader.source=source;},
   getShaderParameter:shader=>!(failCompose&&shader.source.includes('uniform sampler2D cellInfo')),getShaderInfoLog:()=>'forced composer failure',
   getProgramParameter:()=>true,getAttribLocation:()=>0,getUniformLocation:()=>({}),
   checkFramebufferStatus:()=>failFramebuffer?0:proxy.FRAMEBUFFER_COMPLETE,
   readPixels:(x,y,w,h,format,type,dst)=>{if(ArrayBuffer.isView(dst))fill(dst);},getBufferSubData:(target,offset,dst)=>fill(dst),
   clientWaitSync:()=>proxy.ALREADY_SIGNALED};
  proxy=new Proxy(gl,{get:(target,name)=>name in target?target[name]:typeof name==='string'&&/^[A-Z0-9_]+$/.test(name)?(constants.has(name)||constants.set(name,constants.size+1),constants.get(name)):()=>({})});
  contexts.push(log);return proxy;
 }
 const element=options=>{const listeners={};return {width:0,height:0,listeners,addEventListener:(name,cb)=>listeners[name]=cb,
  getContext:type=>type==='2d'?fake2d():type==='webgl2'?(options.webgl2?fakeGL('webgl2',options):null):fakeGL('webgl',{})};};
 const run=(options,compose)=>{
  contexts.length=0;failures.length=0;const surfaces=[];
  globalThis.document={createElement:()=>{const e=element(options);surfaces.push(e);return e;}};globalThis.devicePixelRatio=1;
  const canvas={clientWidth:120,clientHeight:200,width:0,height:0,dataset:{},getContext:()=>fake2d(),dispatchEvent:event=>failures.push(event.type)};
  const mesh={...orbitMesh,regionPositions:orbitMesh.positions,masks:{}};
  return {renderer:new VolumeRenderer(canvas,mesh,false,{compose}),surfaces};
 };
 const muscles=Object.fromEntries(regions.map(key=>[key,{score:0}]));
 const drawsAndPicks=renderer=>{
  glyphDraws.n=0;renderer.draw(0,muscles,'dark');
  assert.ok(renderer.glyphCount>0&&glyphDraws.n>=renderer.glyphCount,'The CPU path composes glyphs');
  assert.equal(renderer.pollReadback(),true);assert.equal(renderer.pick(.5,.5),'chest','The CPU path picks its own frame');
 };
 // Unforced WebGL2 composes on the GPU (the fake accepts every call).
 {const {renderer}=run({webgl2:true},'auto');assert.equal(renderer.gpu,true);assert.equal(renderer.composeFallback,false);renderer.draw(0,muscles,'dark');assert.equal(renderer.readbackPending(),true);assert.equal(renderer.pick(.5,.5),null,'No pick before the copy lands');assert.equal(renderer.pollReadback(),true);assert.equal(renderer.readbackPending(),false);assert.equal(renderer.pick(.5,.5),'chest');}
 for(const [name,options] of [['compile',{webgl2:true,failCompose:true}],['framebuffer',{webgl2:true,failFramebuffer:true}]]){
  const {renderer,surfaces}=run(options,'auto');
  // A compile failure falls back in the constructor; an incomplete
  // framebuffer is found by the first resize, inside the first draw.
  assert.equal(renderer.composeFallback,name==='compile',`${name}: setup-time fallback`);
  drawsAndPicks(renderer);
  assert.equal(renderer.gpu,false);assert.equal(renderer.composeFallback,true,`${name}: falls back`);
  assert.deepEqual(contexts.map(c=>[c.kind,c.lost]),[['webgl2',1],['webgl',0]],`${name}: the failed context is released, a fresh one renders`);
  // The released context's loss event cannot fail the renderer.
  const superseded=surfaces.filter(surface=>surface.listeners.webglcontextlost&&surface!==renderer.surface);assert.equal(superseded.length,1);
  for(const surface of superseded)surface.listeners.webglcontextlost({preventDefault(){}});
  assert.deepEqual(failures,[],`${name}: a superseded surface's loss is ignored`);
  assert.equal(renderer.lost,false);drawsAndPicks(renderer);
  assert.equal(contexts.length,2,`${name}: falls back once`);
  // A loss on the live CPU surface still fails the renderer.
  renderer.surface.listeners.webglcontextlost({preventDefault(){}});assert.deepEqual(failures,['renderfailure']);
  // Explicit GPU compose never falls back.
  if(name==='compile')assert.throws(()=>run(options,'gpu'),/forced composer failure/);
  else{const {renderer:gpu}=run(options,'gpu');assert.throws(()=>gpu.draw(0,muscles,'dark'),/surface unavailable/);}
 }
 // A resize-time failure after GPU frames already drew also falls back.
 {
  const options={webgl2:true},{renderer}=run(options,'auto');renderer.draw(0,muscles,'dark');assert.equal(renderer.gpu,true);
  options.failFramebuffer=true;renderer.canvas.clientWidth=150;
  // Contexts already made keep their options: fail the live one's checks too.
  renderer.gl.checkFramebufferStatus=()=>0;
  drawsAndPicks(renderer);assert.equal(renderer.composeFallback,true);assert.deepEqual(contexts.map(c=>[c.kind,c.lost]),[['webgl2',1],['webgl',0]]);
 }
 globalThis.document=savedDocument;
 console.log('PASS: a WebGL2 composer failure at setup or resize falls back once to CPU compose, which renders and picks; explicit GPU mode still fails');
}
