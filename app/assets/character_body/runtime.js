import {VolumeRenderer,loadMesh} from './renderer.js';
import {colors} from './material.js';
import {MotionLoop} from './motion.js';
import {validateDisplay} from './protocol.js';

const canvas=document.getElementById('body');
const state={ready:false,failed:false,paused:true,reduced:false,hidden:false,visible:false,yaw:0};
let renderer=null,mesh=null,input=null,loadedStyle=null,loadGeneration=0,abort=null,command=-1,retry=-1;
let frames=0,totalMs=0,maxMs=0,lastReport=0,loadMs=0,started=performance.now();
function report(status){
 window.AlkionNative?.postMessage(JSON.stringify({version:1,status,yaw:state.yaw,frames,totalMs,maxMs,loadMs}));
}
function fail(status){state.ready=false;state.failed=true;loop.stop();renderer?.dispose();renderer=null;mesh=null;canvas.getContext('2d')?.clearRect(0,0,canvas.width,canvas.height);report(status);}
function draw(){
 if(!renderer||!state.ready||state.hidden||!state.visible)return;
 try{
  const begin=performance.now();renderer.draw(state.yaw,Object.fromEntries(Object.entries(input.scores).map(([k,score])=>[k,{score}])),input.theme);
  const ms=performance.now()-begin;frames++;totalMs+=ms;maxMs=Math.max(maxMs,ms);
  if(performance.now()-lastReport>1000){lastReport=performance.now();report('ready');}
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
  mesh=next;renderer=new VolumeRenderer(canvas,mesh,input.compact);loadMs=performance.now()-started;state.ready=true;draw();if(state.ready){report('ready');loop.reconcile();}
 }catch(error){if(generation!==loadGeneration)return;fail(error.message==='art_unavailable'?'unavailable':'error');}
}
window.AlkionBody={
 update(value){
  try{
   const next=validateDisplay(value),previous=input;input=next;
   colors[next.theme]={neutral:next.neutral,accent:next.accent};
   state.visible=next.visible;state.reduced=next.reduced;state.paused=next.paused;
   if(next.command!==command){command=next.command;state.yaw=next.yaw;}
   if(loadedStyle!==next.style||next.retry!==retry){retry=next.retry;load();return;}
   if(renderer&&previous?.compact!==next.compact){renderer.dispose();renderer=new VolumeRenderer(canvas,mesh,next.compact);}
   draw();loop.reconcile();
  }catch{fail('error');}
 },
 hostPaused(value){state.hidden=!!value;loop.reconcile();if(!state.hidden)draw();},
 dispose(){loadGeneration++;abort?.abort();state.ready=false;loop.stop();renderer?.dispose();renderer=null;mesh=null;},
};
canvas.addEventListener('renderfailure',()=>fail('error'));
new ResizeObserver(()=>draw()).observe(canvas);
document.addEventListener('visibilitychange',()=>{state.hidden=document.hidden;loop.reconcile();if(!state.hidden)draw();});
window.addEventListener('pagehide',()=>window.AlkionBody.dispose());

window.addEventListener('error',()=>fail('error'));
window.addEventListener('unhandledrejection',()=>fail('error'));
