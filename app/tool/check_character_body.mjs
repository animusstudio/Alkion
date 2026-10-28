import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {webcrypto} from 'node:crypto';
import {runInNewContext} from 'node:vm';
import {validateDisplay,regions} from '../assets/character_body/protocol.js';
import {loadMesh} from '../assets/character_body/renderer.js';
import {fullerMesh} from '../assets/character_body/geometry.js';
import {posedMesh} from '../assets/character_body/pose-geometry.js';
import {MotionLoop} from '../assets/character_body/motion.js';

const display={version:2,style:'male',scores:Object.fromEntries(regions.map(k=>[k,0])),neutral:[240,240,245],accent:[255,104,53],background:[12,12,14],theme:'dark',visible:true,reduced:false,compact:true,paused:true,yaw:0,turn:0,command:0,revision:0,retry:0};
assert.equal(validateDisplay(display),display);
for(const patch of [{version:1},{turn:NaN},{turn:-1},{turn:Math.PI*2},{revision:-1},{revision:.1},{revision:Number.MAX_SAFE_INTEGER+1},{style:'../outside'},{yaw:NaN},{yaw:Math.PI*2},{command:-1},{retry:.1},{neutral:[256,0,0]},{visible:1},{scores:{...display.scores,chest:Infinity}},{scores:{...display.scores,alien:0}},{records:[]}])assert.throws(()=>validateDisplay({...display,...patch}));

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

// Exercise the production runtime with fake graphics and a controlled RAF clock.
// Counts cover all renderer draws, not just outstanding animation callbacks.
const events=[],raf=new Map(),listeners={},documentListeners={};let counter=0,draws=0,disposals=0,loadCount=0,failLoad=false,now=100,lastYaw=0;
const canvas={getContext:()=>({clearRect(){}}),addEventListener:(name,cb)=>listeners[name]=cb};
const window={AlkionNative:{postMessage:json=>events.push(JSON.parse(json))},addEventListener(){}};
const document={getElementById:()=>canvas,fonts:{load:async()=>[{}]},addEventListener:(name,cb)=>documentListeners[name]=cb,hidden:false};
const runtime=readFileSync(new URL('../assets/character_body/runtime.js',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
let resized;
runInNewContext(runtime,{
 window,document,performance:{now:()=>now},AbortController,
 ResizeObserver:class{constructor(callback){resized=callback;}observe(){}},
 MotionLoop:class extends MotionLoop{constructor(state,draw){super(state,draw,{request:cb=>{const id=++counter;raf.set(id,cb);return id;},cancel:id=>raf.delete(id)});}},
 VolumeRenderer:class{draw(yaw){draws++;lastYaw=yaw;}dispose(){disposals++;}},
 loadMesh:async()=>{loadCount++;if(failLoad)throw new Error('art_unavailable');return {};},colors:{},validateDisplay,
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
update({paused:true});resized();assert.equal(raf.size,1);window.AlkionBody.dispose();assert.equal(raf.size,0);baseline=draws;frame();assert.equal(draws,baseline);assert.ok(disposals>=2);
console.log('PASS: protocol v2, exact style dispatch, one latest draw/frame, no identical paused redraws, cumulative drag continuity, lifecycle/reduced motion/retry/disposal');
