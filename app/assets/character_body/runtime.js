import {VolumeRenderer,loadMesh} from './renderer.js';
import {colors} from './material.js';
import {MotionLoop} from './motion.js';
import {validateDisplay} from './protocol.js';

const canvas=document.getElementById('body');
const state={ready:false,failed:false,paused:true,reduced:false,hidden:false,visible:false,yaw:0};
let renderer=null,mesh=null,input=null,muscles=null,loadedStyle=null,loadGeneration=0,abort=null,command=-1,turn=0,retry=-1,hostHidden=false;
let frames=0,totalMs=0,maxMs=0,lastReport=0,loadMs=0,started=performance.now();
function report(status){
 window.AlkionNative?.postMessage(JSON.stringify({version:2,status,yaw:state.yaw,command,turn,revision:input?.revision??0,frames,totalMs,maxMs,loadMs}));
}
function fail(status){state.ready=false;state.failed=true;loop.stop();renderer?.dispose();renderer=null;mesh=null;canvas.getContext('2d')?.clearRect(0,0,canvas.width,canvas.height);report(status);}
function draw(){
 if(!renderer||!state.ready||state.hidden||!state.visible)return;
 try{
  const begin=performance.now();renderer.draw(state.yaw,muscles,input.theme);
  const ms=performance.now()-begin;frames++;totalMs+=ms;maxMs=Math.max(maxMs,ms);
  if(frames===1||performance.now()-lastReport>1000){lastReport=performance.now();report('ready');}
 }catch{fail('error');}
}
const loop=new MotionLoop(state,draw);
async function load(){
 const generation=++loadGeneration;abort?.abort();abort=new AbortController();const signal=abort.signal,style=input.style;
 state.ready=false;state.failed=false;loop.stop();renderer?.dispose();renderer=null;mesh=null;loadedStyle=input.style;
 canvas.getContext('2d')?.clearRect(0,0,canvas.width,canvas.height);started=performance.now();frames=0;totalMs=0;maxMs=0;report('loading');
 try{
  const fonts=await document.fonts.load('400 10px "Space Mono"');if(!fonts.length)throw new Error('font');
  const next=await loadMesh(style,signal);if(generation!==loadGeneration)return;
  mesh=next;renderer=new VolumeRenderer(canvas,mesh,input.compact);loadMs=performance.now()-started;state.ready=true;loop.invalidate();
 }catch(error){if(generation!==loadGeneration)return;fail(error.message==='art_unavailable'?'unavailable':'error');}
}
window.AlkionBody={
 update(value){
  try{
   const next=validateDisplay(value),previous=input;input=next;
   const scoresChanged=!previous||Object.keys(next.scores).some(key=>next.scores[key]!==previous.scores[key]);
   if(scoresChanged)muscles=Object.fromEntries(Object.entries(next.scores).map(([key,score])=>[key,{score}]));
   let changed=scoresChanged||!previous||next.theme!==previous.theme||next.compact!==previous.compact||
    next.neutral.some((value,i)=>value!==previous.neutral[i])||next.accent.some((value,i)=>value!==previous.accent[i]);
   colors[next.theme]={neutral:next.neutral,accent:next.accent};
   state.visible=next.visible;state.reduced=next.reduced;state.paused=next.paused;
   const yaw=state.yaw;
   if(next.command!==command){command=next.command;state.yaw=next.yaw;}
   else if(next.turn!==turn){state.yaw=(state.yaw+next.turn-turn)%(Math.PI*2);if(state.yaw<0)state.yaw+=Math.PI*2;}
   turn=next.turn;changed=changed||state.yaw!==yaw||previous?.visible!==next.visible;
   if(loadedStyle!==next.style||next.retry!==retry){retry=next.retry;load();return;}
   if(renderer&&previous?.compact!==next.compact){renderer.dispose();renderer=new VolumeRenderer(canvas,mesh,next.compact);}
   if(changed)loop.invalidate();else loop.reconcile();
  }catch{fail('error');}
 },
 hostPaused(value){hostHidden=!!value;const hidden=hostHidden||document.hidden,changed=state.hidden!==hidden;state.hidden=hidden;if(changed&&!state.hidden)loop.invalidate();else loop.reconcile();},
 dispose(){loadGeneration++;abort?.abort();state.ready=false;loop.stop();renderer?.dispose();renderer=null;mesh=null;},
};
canvas.addEventListener('renderfailure',()=>fail('error'));
new ResizeObserver(()=>loop.invalidate()).observe(canvas);
document.addEventListener('visibilitychange',()=>window.AlkionBody.hostPaused(hostHidden));
window.addEventListener('pagehide',()=>window.AlkionBody.dispose());

window.addEventListener('error',()=>fail('error'));
window.addEventListener('unhandledrejection',()=>fail('error'));
