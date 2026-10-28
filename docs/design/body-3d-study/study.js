import {BodyRenderer} from './renderer.js';
import {calculateWorkload,canonicalMuscles} from './workload.js';
const $=id=>document.getElementById(id);
const labels={chest:'Chest',back:'Back',shoulders:'Shoulders',quads:'Quads',hamstrings:'Hamstrings',calves:'Calves',biceps:'Biceps',triceps:'Triceps'};
const fixtureLabels={
 'planned-resolved-eight':'Planned · all eight groups',
 'active-before-first-set':'Active · before first working set',
 'active-mixed-completed':'Active · mixed coverage',
 'saved-actual':'Finished · saved working sets',
 'unknown-only':'Finished · unknown muscle groups',
 'no-side-or-name-inference':'Active · unsupported side / custom keys',
 'unknown-warmup-evidence':'Finished · set kind unknown',
 'empty-selection':'Planned · empty workout',
 'warmup-only':'Finished · warmups only',
 'deleted-only':'Finished · deleted sets only',
 'read-loading':'Finished · loading',
 'read-unavailable':'Finished · unavailable'
};
const reduce=matchMedia('(prefers-reduced-motion: reduce)');
const state={yaw:-0.55,paused:reduce.matches,hidden:document.hidden,frame:0,last:0,dirty:true,theme:'dark',part:'',input:null,result:null,history:[],renderers:[],failed:false,ready:false};
const views=[{canvas:$('large-body'),fallback:$('large-fallback'),visible:false},{canvas:$('compact-body'),fallback:$('compact-fallback'),visible:false}];
let fixtures;
function orientation(){
 const deg=((state.yaw*180/Math.PI)%360+360)%360;
 if(deg<12||deg>348)return 'Front';
 if(Math.abs(deg-180)<12)return 'Back';
 if(Math.abs(deg-90)<12||Math.abs(deg-270)<12)return 'Profile';
 return 'Three-quarter';
}
function motionLabels(){
 $('motion').textContent=reduce.matches?'Reduced motion':state.paused?'Resume':'Pause';
 $('motion').disabled=!state.ready||state.failed||reduce.matches;
 $('motion').setAttribute('aria-pressed',String(!state.paused));
 $('orientation').textContent=orientation();
 $('motion-state').textContent=state.failed?'Preview unavailable':state.paused?'Rotation held':'Slow rotation';
}
function eligible(){return state.ready&&!state.failed&&!state.hidden&&views.some(view=>view.visible);}
function schedule(){
 if(!eligible()||state.frame)return;
 if(state.paused&&!state.dirty)return;
 state.frame=requestAnimationFrame(tick);
}
function tick(time){
 state.frame=0;
 if(!eligible()){state.last=0;return;}
 if(!state.paused){
   if(state.last)state.yaw+=(Math.min(time-state.last,100)/52000)*Math.PI*2;
   state.last=time;state.dirty=true;
 }else state.last=0;
 if(state.dirty){
   try{
     for(const view of views)if(view.visible)view.renderer.draw(state.yaw,state.result?.muscles||{},state.theme,state.part);
   }catch(error){fail(error);return;}
   motionLabels();state.dirty=false;
 }
 schedule();
}
function invalidate(){state.dirty=true;schedule();}
function hold(){state.paused=true;state.last=0;motionLabels();}
function stopFrame(){if(state.frame)cancelAnimationFrame(state.frame);state.frame=0;state.last=0;}
function fail(error){
 state.failed=true;state.ready=false;stopFrame();
 for(const view of views){view.canvas.hidden=true;view.fallback.hidden=false;view.fallback.textContent='Body preview unavailable. Set counts remain available below.';}
 for(const button of document.querySelectorAll('[data-snap],#motion,#part,#export'))button.disabled=true;
 $('retry').hidden=false;motionLabels();
 console.error('Body study render failure:',error.message);
}
function updateData(){
 state.result=calculateWorkload(state.input);
 const {availability,muscles,coverage,mode}=state.result;
 const title=mode==='planned'?'Planned workload':'Workout workload';
 $('metric-title').textContent=title;$('compact-mode').textContent=title;
 $('today-title').textContent=mode==='planned'?'Illustrative workout':mode==='active'?'Workout in progress':'Finished workout';
 $('counts').replaceChildren();
 $('scale').hidden=availability!=='ready'||Boolean(state.part);
 $('set-total').textContent=availability==='ready'?`${coverage.mappedSets} mapped ${coverage.mappedSets===1?'set':'sets'}`:'—';
 const coverageText=availability==='loading'?'Loading saved workout…':availability==='unavailable'?'Workout unavailable. No workload values can be shown.':
   coverage.status==='empty'?(mode==='active'?'No completed working sets yet. All regions are neutral.':'No working sets to map. All regions are neutral.'):
   coverage.status==='complete'?`All ${coverage.mappedSets} working ${coverage.mappedSets===1?'set':'sets'} mapped.`:
   `${coverage.mappedSets} mapped · ${coverage.unmappedSets} unknown muscle · ${coverage.unknownKindSets} unknown set kind. Unknowns stay unmapped.`;
 $('coverage').textContent=coverageText;$('compact-coverage').textContent=coverageText;
 $('compact-counts').textContent=availability!=='ready'?'Values unavailable':canonicalMuscles.filter(id=>muscles[id].count>0).map(id=>`${labels[id]} ${muscles[id].count}`).join(' · ')||'No mapped working sets';
 if(availability==='ready')for(const id of canonicalMuscles){
   const row=document.createElement('div');row.className='count-row';
   const name=document.createElement('span');name.className='muscle-label';
   const swatch=document.createElement('i');swatch.className='swatch';swatch.setAttribute('aria-hidden','true');
   swatch.style.background=`color-mix(in srgb,var(--accent) ${muscles[id].score*100}%,var(--neutral))`;
   name.append(swatch,labels[id]);
   const value=document.createElement('span');value.textContent=`${muscles[id].count} ${muscles[id].count===1?'set':'sets'}`;
   row.append(name,value);$('counts').append(row);
 }
 const max=availability==='ready'?Math.max(...Object.values(muscles).map(m=>m.count)):0;
 $('scale-max').textContent=`${max} ${max===1?'set':'sets'} · highest`;
 for(const id of ['complete','remove'])$(id).disabled=availability!=='ready';
 $('undo').disabled=!state.history.length;
 invalidate();
}
function selectFixture(id){
 const source=fixtures.cases.find(c=>c.id===id);
 state.input=structuredClone({mode:source.mode,availability:source.availability,exercises:source.exercises});state.history=[];
 $('edit-state').textContent='';updateData();
}
function mutate(kind){
 state.history.push(structuredClone(state.input));
 // Live actions model authoritative active-session set changes, not scores.
 state.input.mode='active';
 let exercise=state.input.exercises.find(e=>e.muscleGroup==='chest');
 if(!exercise){exercise={muscleGroup:'chest',sets:[]};state.input.exercises.push(exercise);}
 if(kind==='complete'){
   const pending=exercise.sets.find(s=>!s.completed&&!s.deleted&&s.isWarmup===false);
   if(pending)pending.completed=true;else exercise.sets.push({completed:true,isWarmup:false,deleted:false});
   $('edit-state').textContent='Completed one synthetic chest working set.';
 }else{
   const last=exercise.sets.findLast(s=>s.completed&&!s.deleted&&s.isWarmup===false);
   if(last){last.deleted=true;$('edit-state').textContent='Removed the last completed chest working set.';}
   else{$('edit-state').textContent='There is no completed chest working set to remove.';state.history.pop();}
 }
 updateData();
}
function pointerControls(canvas){
 let drag=null;
 canvas.addEventListener('pointerdown',event=>{if(event.isPrimary&&event.button===0)drag={id:event.pointerId,x:event.clientX,y:event.clientY,yaw:state.yaw,active:false};});
 canvas.addEventListener('pointermove',event=>{
   if(!drag||event.pointerId!==drag.id)return;
   const dx=event.clientX-drag.x,dy=event.clientY-drag.y;
   if(!drag.active){
     if(Math.abs(dy)>8&&Math.abs(dy)>Math.abs(dx)){drag=null;return;}
     if(Math.abs(dx)<6||Math.abs(dx)<=Math.abs(dy))return;
     drag.active=true;hold();canvas.setPointerCapture(event.pointerId);
   }
   state.yaw=drag.yaw+dx/Math.max(240,canvas.clientWidth)*Math.PI*1.4;invalidate();
 });
 const end=event=>{if(drag?.id===event.pointerId){drag=null;if(canvas.hasPointerCapture(event.pointerId))canvas.releasePointerCapture(event.pointerId);}};
 canvas.addEventListener('pointerup',end);canvas.addEventListener('pointercancel',end);canvas.addEventListener('lostpointercapture',()=>drag=null);
 canvas.addEventListener('keydown',event=>{
   if(!['ArrowLeft','ArrowRight','Home'].includes(event.key))return;
   event.preventDefault();hold();state.yaw=event.key==='Home'?0:state.yaw+(event.key==='ArrowLeft'?-1:1)*Math.PI/18;invalidate();
 });
 canvas.addEventListener('renderfailure',()=>fail(new Error('Graphics context lost')));
}
const observer=new IntersectionObserver(entries=>{
 for(const entry of entries){const view=views.find(v=>v.canvas===entry.target);view.visible=entry.isIntersecting;}
 if(!views.some(v=>v.visible))stopFrame();else{state.last=0;invalidate();}
},{threshold:0.01});
for(const view of views){observer.observe(view.canvas);pointerControls(view.canvas);}
new ResizeObserver(()=>invalidate()).observe($('large-stage'));
new ResizeObserver(()=>invalidate()).observe($('compact-stage'));
document.addEventListener('visibilitychange',()=>{state.hidden=document.hidden;stopFrame();if(!state.hidden)invalidate();});
reduce.addEventListener('change',event=>{if(event.matches){hold();stopFrame();invalidate();}motionLabels();});
$('theme').addEventListener('click',()=>{state.theme=state.theme==='dark'?'light':'dark';document.documentElement.dataset.theme=state.theme;$('theme').textContent=state.theme==='dark'?'Light theme':'Dark theme';invalidate();});
$('motion').addEventListener('click',()=>{if(reduce.matches)return;state.paused=!state.paused;state.last=0;motionLabels();invalidate();});
for(const button of document.querySelectorAll('[data-snap]'))button.addEventListener('click',()=>{hold();state.yaw=Number(button.dataset.snap);invalidate();});
$('part').addEventListener('change',()=>{state.part=$('part').value;$('scale').hidden=Boolean(state.part)||state.result?.availability!=='ready';invalidate();});
$('fixture').addEventListener('change',()=>selectFixture($('fixture').value));
$('complete').addEventListener('click',()=>mutate('complete'));
$('remove').addEventListener('click',()=>mutate('remove'));
$('undo').addEventListener('click',()=>{if(!state.history.length)return;state.input=state.history.pop();$('edit-state').textContent='Restored the previous synthetic workout sets.';updateData();});
async function loadMesh(){
 $('retry').hidden=true;
 try{
   const response=await fetch('assets/body.mesh.json');if(!response.ok)throw new Error(`Mesh HTTP ${response.status}`);
   const mesh=await response.json();
   if(!Array.isArray(mesh.positions)||!Array.isArray(mesh.indices)||mesh.version!==1)throw new Error('Invalid mesh contract');
   await document.fonts.load('400 10px "Space Mono"');
   for(const view of views){view.renderer?.dispose();view.renderer=new BodyRenderer(view.canvas,mesh);view.canvas.hidden=false;view.fallback.hidden=true;}
   state.ready=true;state.failed=false;
   for(const button of document.querySelectorAll('[data-snap],#motion,#part,#export'))button.disabled=false;
   motionLabels();invalidate();
 }catch(error){fail(error);}
}
$('retry').addEventListener('click',loadMesh);
$('export').addEventListener('click',()=>{
  if(!state.ready||state.failed)return;
  // Export exactly the current mesh/material view, without page UI or fixtures.
  hold();
  const view=views[0];
  try{
    view.renderer.draw(state.yaw,state.result?.muscles||{},state.theme,state.part);
    view.canvas.toBlob(blob=>{
      if(!blob){$('export-state').textContent='The body image could not be exported.';return;}
      const link=document.createElement('a');const url=URL.createObjectURL(blob);
      link.href=url;link.download=`alkion-body-${state.theme}-${orientation().toLowerCase()}.png`;
      document.body.append(link);link.click();link.remove();
      setTimeout(()=>URL.revokeObjectURL(url),1000);
      $('export-state').textContent='Exported the current body as a transparent PNG.';
    },'image/png');
    invalidate();
  }catch(error){$('export-state').textContent='The body image could not be exported.';}
});
async function initialize(){
 try{
   const response=await fetch('assets/body_workload_cases.json');if(!response.ok)throw new Error('Workout examples unavailable');
   fixtures=await response.json();
   for(const c of fixtures.cases){const got=calculateWorkload(c);if(JSON.stringify(sort(got))!==JSON.stringify(sort(c.expected)))throw new Error(`Calculator contract mismatch: ${c.id}`);}
   $('fixture').replaceChildren(...fixtures.cases.map(c=>{const option=document.createElement('option');option.value=c.id;option.textContent=fixtureLabels[c.id]||c.id;return option;}));
   $('fixture').disabled=false;$('theme').disabled=false;
   selectFixture('planned-resolved-eight');
 }catch(error){$('coverage').textContent='Workout examples unavailable. No workload values can be shown.';$('compact-counts').textContent='Values unavailable';console.error(error.message);}
 await loadMesh();
}
function sort(value){if(Array.isArray(value))return value.map(sort);if(value&&typeof value==='object')return Object.fromEntries(Object.keys(value).sort().map(k=>[k,sort(value[k])]));return value;}
// Read-only diagnostics for the bounded browser checkpoint; no user data.
window.bodyStudy={get state(){return {yaw:state.yaw,paused:state.paused,hidden:state.hidden,ready:state.ready,failed:state.failed,reducedMotion:reduce.matches,frames:views.map(v=>v.renderer?.drawCount||0),visible:views.map(v=>v.visible),result:structuredClone(state.result)};}};
initialize();
