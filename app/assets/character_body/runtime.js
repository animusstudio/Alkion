import {VolumeRenderer,loadMesh} from './renderer.js';
import {colors} from './material.js';
import {MotionLoop} from './motion.js';
import {validateDisplay,validatePick,protocolVersion} from './protocol.js';

const canvas=document.getElementById('body');
const state={ready:false,failed:false,paused:true,reduced:false,hidden:false,visible:false,yaw:0};
let renderer=null,mesh=null,input=null,muscles=null,loadedStyle=null,loadGeneration=0,abort=null,command=-1,turn=0,retry=-1,hostHidden=false;
let rendered=null,frameId=0,layout=0;
let frames=0,totalMs=0,maxMs=0,lastReport=0,loadMs=0,started=performance.now(),stages={},lease=0;
const meshes=new Map();let fontReady=null,needsLoad=false,loading=false;
// Aggregate timing only: frame intervals during continuous motion, draw stage
// times and message counts. Fixed rings, summarized at most once per second;
// the native host logs them only in debug or an explicit timing build.
const ring=256,timing={interval:new Float32Array(ring),draw:new Float32Array(ring),scratch:new Float32Array(ring),n:0,at:0,last:0,msgs:0,gl:0,read:0,compose:0,frames:0,summary:{},summarized:0};
const round=value=>Math.round(value*100)/100;
function percentile(values,count,p){const s=timing.scratch.subarray(0,count);s.set(values.subarray(0,count));s.sort();return round(s[Math.min(count-1,Math.floor(p*count))]);}
function summarize(now){
 if(now-timing.summarized<1000||!timing.n)return;timing.summarized=now;const n=Math.min(timing.n,ring),f=Math.max(1,timing.frames),out=timing.summary;
 out.tFrames=timing.frames;out.tMsgs=timing.msgs;out.iP50=percentile(timing.interval,n,.5);out.iP90=percentile(timing.interval,n,.9);out.iMax=percentile(timing.interval,n,1);
 out.dP50=percentile(timing.draw,n,.5);out.dP90=percentile(timing.draw,n,.9);out.glMs=round(timing.gl/f);out.readMs=round(timing.read/f);out.composeMs=round(timing.compose/f);
 timing.n=0;timing.at=0;timing.frames=0;timing.msgs=0;timing.gl=0;timing.read=0;timing.compose=0;
}
function report(status){
 window.AlkionNative?.postMessage(JSON.stringify({version:protocolVersion,status,yaw:state.yaw,command,turn,revision:input?.revision??0,frames,totalMs:round(totalMs),maxMs:round(maxMs),loadMs:round(loadMs),lease,...stages,...timing.summary,...(input?.interaction?.enabled&&rendered?rendered:{})}));
}
function fail(status){rendered=null;state.ready=false;state.failed=true;loop.stop();renderer?.dispose();renderer=null;mesh=null;canvas.getContext('2d')?.clearRect(0,0,canvas.width,canvas.height);report(status);}
function draw(){
 if(!renderer||!state.ready||state.hidden||!state.visible)return;
 try{
  const begin=performance.now();renderer.draw(state.yaw,muscles,input.theme,'characters',input.interaction?.enabled?input.interaction.selected:null,input.view);
  rendered={generation:input.interaction?.generation??0,frame:++frameId,load:loadGeneration,layout};
  const end=performance.now(),ms=end-begin;if(frames===0)stages.firstFrameMs=round(end-started);frames++;totalMs+=ms;maxMs=Math.max(maxMs,ms);
  // Only consecutive frames count as intervals; an idle gap is not a frame.
  if(timing.last&&begin-timing.last<100){timing.interval[timing.at]=begin-timing.last;timing.draw[timing.at]=ms;timing.at=(timing.at+1)%ring;timing.n++;}
  timing.last=begin;timing.frames++;timing.gl+=renderer.stageGl||0;timing.read+=renderer.stageRead||0;timing.compose+=renderer.stageCompose||0;summarize(end);
  if(input.interaction?.enabled||frames===1||performance.now()-lastReport>1000){lastReport=performance.now();report('ready');}
 }catch{fail('error');}
}
const loop=new MotionLoop(state,draw);
function cancelLoad(){
 if(!loading)return;loadGeneration++;abort?.abort();loading=false;needsLoad=true;
}
async function load(){
 if(!input||!state.visible||state.hidden){needsLoad=true;return;}
 rendered=null;const generation=++loadGeneration;abort?.abort();abort=new AbortController();const signal=abort.signal,style=input.style;
 needsLoad=false;loading=true;loadedStyle=style;state.ready=false;state.failed=false;loop.stop();renderer?.dispose();renderer=null;mesh=null;
 canvas.getContext('2d')?.clearRect(0,0,canvas.width,canvas.height);started=performance.now();frames=0;totalMs=0;maxMs=0;stages={cacheHit:meshes.has(style)?1:0};report('loading');
 try{
  const fontStart=performance.now();
  fontReady??=document.fonts.load('400 10px "Space Mono"').then(fonts=>{if(!fonts.length)throw new Error('font');}).catch(error=>{fontReady=null;throw error;});
  const meshReady=meshes.has(style)?Promise.resolve(meshes.get(style)):loadMesh(style,signal,stages);
  const [,next]=await Promise.all([fontReady.then(()=>{stages.fontMs=performance.now()-fontStart;}),meshReady]);
  if(generation!==loadGeneration||signal.aborted)return;
  // Exactly two approved styles, prepared only on demand. No unbounded snapshots.
  meshes.set(style,next);mesh=next;loadedStyle=style;
  const setup=performance.now();renderer=new VolumeRenderer(canvas,mesh,input.compact);stages.rendererMs=performance.now()-setup;
  loadMs=performance.now()-started;loading=false;state.ready=true;loop.invalidate();
 }catch(error){if(generation!==loadGeneration)return;loading=false;fail(error.message==='art_unavailable'?'unavailable':'error');}
}

window.AlkionBody={
 update(value){
  timing.msgs++;
  try{
   const next=validateDisplay(value),previous=input;input=next;
   if(JSON.stringify(previous)!==JSON.stringify(next))rendered=null;
   const scoresChanged=!previous||Object.keys(next.scores).some(key=>next.scores[key]!==previous.scores[key]);
   if(scoresChanged)muscles=Object.fromEntries(Object.entries(next.scores).map(([key,score])=>[key,{score}]));
   let changed=JSON.stringify(next.view)!==JSON.stringify(previous?.view)||scoresChanged||JSON.stringify(next.interaction)!==JSON.stringify(previous?.interaction)||!previous||next.theme!==previous.theme||next.compact!==previous.compact||
    next.neutral.some((value,i)=>value!==previous.neutral[i])||next.accent.some((value,i)=>value!==previous.accent[i]);
   colors[next.theme]={neutral:next.neutral,accent:next.accent};
   state.visible=next.visible;state.reduced=next.reduced;state.paused=next.paused;
   const yaw=state.yaw;
   if(next.command!==command){command=next.command;state.yaw=next.yaw;}
   else if(next.turn!==turn){state.yaw=(state.yaw+next.turn-turn)%(Math.PI*2);if(state.yaw<0)state.yaw+=Math.PI*2;}
   turn=next.turn;changed=changed||state.yaw!==yaw||previous?.visible!==next.visible;
   if(next.retry!==retry){if(retry>=0||next.retry>0){meshes.delete(next.style);needsLoad=true;}retry=next.retry;}
   if(!state.visible||state.hidden){cancelLoad();loop.reconcile();return;}
   if(loadedStyle!==next.style||needsLoad||(!state.ready&&!loading&&!state.failed)){if(!loading||loadedStyle!==next.style){cancelLoad();load();}return;}
   if(renderer&&renderer.compact!==next.compact){renderer.compact=next.compact;renderer.pixels=null;}
   if(changed)loop.invalidate();else loop.reconcile();
  }catch{fail('error');}
 },
 pick(value){
  let request;try{request=validatePick(value);}catch{return;}
  const valid=input?.interaction?.enabled&&state.ready&&!state.hidden&&state.visible&&state.paused&&rendered&&
   ['generation','frame','load','layout'].every(key=>request[key]===rendered[key]);
  const region=valid?renderer.pick(request.x,request.y):null;
  window.AlkionNative?.postMessage(JSON.stringify({...request,type:'pick',region,lease}));
 },
 hostPaused(value){hostHidden=!!value;const hidden=hostHidden||document.hidden,changed=state.hidden!==hidden;state.hidden=hidden;if(changed)rendered=null;if(hidden)cancelLoad();if(changed&&!hidden&&needsLoad)load();else if(changed&&!hidden)loop.invalidate();else loop.reconcile();},
 // A pooled native surface starts a new lease without retaining caller state.
 reset(value){if(value===lease)return;lease=value;rendered=null;canvas.getContext('2d')?.clearRect(0,0,canvas.width,canvas.height);input=null;muscles=null;command=-1;turn=0;retry=-1;state.visible=false;state.paused=true;loop.stop();cancelLoad();if(!state.ready)needsLoad=true;state.failed=false;started=performance.now();frames=0;totalMs=0;maxMs=0;loadMs=0;stages={cacheHit:state.ready?1:0};},
 dispose(){rendered=null;loadGeneration++;abort?.abort();state.ready=false;loop.stop();renderer?.dispose();renderer=null;mesh=null;meshes.clear();fontReady=null;},
};
canvas.addEventListener('renderfailure',()=>fail('error'));
new ResizeObserver(()=>{rendered=null;layout++;loop.invalidate();}).observe(canvas);
document.addEventListener('visibilitychange',()=>window.AlkionBody.hostPaused(hostHidden));
window.addEventListener('pagehide',()=>window.AlkionBody.dispose());

window.addEventListener('error',()=>fail('error'));
window.addEventListener('unhandledrejection',()=>fail('error'));
