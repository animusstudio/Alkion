import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {webcrypto} from 'node:crypto';
import {runInNewContext} from 'node:vm';
import {validateDisplay,regions} from '../assets/character_body/protocol.js';
import {loadMesh} from '../assets/character_body/renderer.js';
import {fullerMesh} from '../assets/character_body/geometry.js';
import {posedMesh} from '../assets/character_body/pose-geometry.js';
import {MotionLoop} from '../assets/character_body/motion.js';

const display={version:1,style:'male',scores:Object.fromEntries(regions.map(k=>[k,0])),neutral:[240,240,245],accent:[255,104,53],background:[12,12,14],theme:'dark',visible:true,reduced:false,compact:true,paused:true,yaw:0,command:0,retry:0};
assert.equal(validateDisplay(display),display);
for(const patch of [{version:2},{style:'../outside'},{yaw:NaN},{yaw:Math.PI*2},{command:-1},{retry:.1},{neutral:[256,0,0]},{visible:1},{scores:{...display.scores,chest:Infinity}},{scores:{...display.scores,alien:0}},{records:[]}])assert.throws(()=>validateDisplay({...display,...patch}));

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

// Exercise runtime scheduling with fake graphics, not a second implementation.
const events=[],raf=new Map(),listeners={},documentListeners={};let counter=0,draws=0,disposals=0,loadCount=0,failLoad=false;
const canvas={getContext:()=>({clearRect(){}}),addEventListener:(name,cb)=>listeners[name]=cb};
const window={AlkionNative:{postMessage:json=>events.push(JSON.parse(json))},addEventListener(){}};
const runtime=readFileSync(new URL('../assets/character_body/runtime.js',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
runInNewContext(runtime,{
 window,document:{getElementById:()=>canvas,fonts:{load:async()=>[{}]},addEventListener:(name,cb)=>documentListeners[name]=cb,hidden:false},
 performance:{now:()=>100},AbortController,ResizeObserver:class{observe(){}},
 requestAnimationFrame:cb=>{const id=++counter;raf.set(id,cb);return id;},cancelAnimationFrame:id=>raf.delete(id),
 // The real loop receives sandbox RAF explicitly rather than global Node RAF.
 MotionLoop:class extends MotionLoop{constructor(state,draw){super(state,draw,{request:cb=>{const id=++counter;raf.set(id,cb);return id;},cancel:id=>raf.delete(id)});}},
 VolumeRenderer:class{draw(){draws++;}dispose(){disposals++;}},
 loadMesh:async()=>{loadCount++;if(failLoad)throw new Error('art_unavailable');return {};},colors:{},validateDisplay,
});
const flush=()=>new Promise(resolve=>setImmediate(resolve));
window.AlkionBody.update(display);await flush();assert.equal(draws,1);assert.equal(raf.size,0);assert.equal(events.at(-1).status,'ready');
window.AlkionBody.update({...display,paused:false});assert.equal(raf.size,1);
window.AlkionBody.update({...display,paused:false,visible:false});assert.equal(raf.size,0);
window.AlkionBody.update({...display,paused:false,reduced:true});assert.equal(raf.size,0);
window.AlkionBody.update({...display,paused:false});assert.equal(raf.size,1);
window.AlkionBody.hostPaused(true);assert.equal(raf.size,0);window.AlkionBody.hostPaused(false);assert.equal(raf.size,1);
listeners.renderfailure();assert.equal(raf.size,0);assert.equal(events.at(-1).status,'error');
failLoad=true;window.AlkionBody.update({...display,retry:1});await flush();assert.equal(events.at(-1).status,'unavailable');
failLoad=false;window.AlkionBody.update({...display,retry:2,style:'female'});await flush();assert.equal(events.at(-1).status,'ready');assert.equal(loadCount,3);
window.AlkionBody.dispose();assert.equal(raf.size,0);assert.ok(disposals>=2);
console.log('PASS: bounded protocol, approved style dispatch, hash/fetch failures, runtime lifecycle, reduced motion, retry and disposal');
