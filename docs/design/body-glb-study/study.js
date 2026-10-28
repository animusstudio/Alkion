import {VolumeRenderer,loadMesh} from './renderer.js';
import {regionColor} from './material.js';
import {MotionLoop} from './motion.js';
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
const media=matchMedia('(prefers-reduced-motion: reduce)');
const state={view:'front',yaw:0,theme:'dark',renderMode:'characters',input:null,result:null,history:[],ready:false,failed:false,paused:false,reduced:media.matches,hidden:document.hidden,visible:false};
const views=[{canvas:$('large-body'),fallback:$('large-fallback'),compact:false},{canvas:$('compact-body'),fallback:$('compact-fallback'),compact:true}];
let fixtures;let mesh;
const loop=new MotionLoop(state,draw);
for(const view of views)view.visible=false;
function draw(){
 if(!state.ready||state.hidden)return;
 try{for(const view of views)if(view.visible)view.renderer.draw(state.yaw,state.result?.muscles||{},state.theme,state.renderMode);}
 catch(error){failArtwork(error);}
}
function motionLabels(label){
 if(state.failed){$('motion').disabled=true;$('motion').textContent='Rotation off';$('motion-state').textContent='Body preview unavailable · retry below';$('compact-view').textContent='Unavailable';return;}
 const auto=!state.paused&&!state.reduced;
 $('motion').textContent=state.reduced?'Rotation off':auto?'Pause':'Resume';
 $('motion').disabled=!state.ready||state.reduced;
 $('motion-state').textContent=state.reduced?'Reduced motion · drag or choose a view':auto?'Rotating · one turn in 52 seconds':label||'View held · resume when ready';
 $('compact-view').textContent=auto?'Rotating':state.view==='front'?'Front':state.view==='back'?'Back':'View held';
 for(const button of document.querySelectorAll('[data-view]'))button.setAttribute('aria-pressed',String(!auto&&button.dataset.view===state.view));
}
function failArtwork(error){
 state.ready=false;state.failed=true;loop.stop();
 for(const view of views){view.canvas.hidden=true;view.fallback.hidden=false;view.fallback.textContent='Body preview unavailable. Exact set counts remain available.';view.renderer?.dispose();view.renderer=null;}
 for(const button of document.querySelectorAll('[data-view]'))button.disabled=true;
 motionLabels();$('retry').hidden=false;console.error('Source body:',error.message);
}
function updateData(){
 state.result=calculateWorkload(state.input);
 const {availability,muscles,coverage,mode}=state.result;
 const title=mode==='planned'?'Planned workload':'Workout workload';
 $('metric-title').textContent=title;$('compact-mode').textContent=title;
 $('compact-title').textContent=mode==='planned'?'Planned workout':mode==='active'?'Active workout':'Saved workout';
 $('compact-total').textContent=availability==='ready'?String(coverage.mappedSets):'—';
 $('counts').replaceChildren();$('scale').hidden=availability!=='ready';
 $('set-total').textContent=availability==='ready'?`${coverage.mappedSets} mapped ${coverage.mappedSets===1?'set':'sets'}`:'—';
 const coverageText=availability==='loading'?'Loading saved workout…':availability==='unavailable'?'Workout unavailable. No workload values can be shown.':
   coverage.status==='empty'?(mode==='active'?'No completed working sets yet. All regions are neutral.':'No working sets to map. All regions are neutral.'):
   coverage.status==='complete'?`All ${coverage.mappedSets} ${mode==='planned'?'planned ':''}working ${coverage.mappedSets===1?'set':'sets'} mapped.`:
   `${coverage.mappedSets} mapped · ${coverage.unmappedSets} unknown muscle · ${coverage.unknownKindSets} unknown set kind. Unknowns stay unmapped.`;
 $('coverage').textContent=coverageText;$('compact-coverage').textContent=coverageText;
 $('compact-counts').textContent=availability!=='ready'?'Values unavailable':canonicalMuscles.filter(id=>muscles[id].count>0).map(id=>`${labels[id]} ${muscles[id].count}`).join(' · ')||'No mapped working sets';
 for(const id of canonicalMuscles){
   const row=document.createElement('div');row.className='count-row';
   const name=document.createElement('span');name.className='muscle-label';
   const swatch=document.createElement('i');swatch.className='swatch';swatch.setAttribute('aria-hidden','true');
   swatch.style.background=regionColor(id,muscles,state.theme);name.append(swatch,labels[id]);
   const value=document.createElement('span');value.textContent=availability==='ready'?`${muscles[id].count} ${muscles[id].count===1?'set':'sets'}`:'—';
   row.append(name,value);$('counts').append(row);
 }
 const max=availability==='ready'?Math.max(...Object.values(muscles).map(m=>m.count)):0;
 $('scale-max').textContent=`${max} ${max===1?'set':'sets'} · highest`;
 document.querySelector('.metric-note').textContent=mode==='planned'?
   "Resolved planned working sets, relative to this workout's highest count. Warmups and deleted sets do not count. No physiological intensity is implied.":
   "Completed working sets, relative to this workout's highest count. Warmups and pending or deleted sets do not count. No physiological intensity is implied.";
 for(const id of ['complete','remove'])$(id).disabled=availability!=='ready';
 $('undo').disabled=!state.history.length;
 draw();
}
function selectFixture(id){
 const source=fixtures.cases.find(c=>c.id===id);
 state.input=structuredClone({mode:source.mode,availability:source.availability,exercises:source.exercises});state.history=[];
 $('edit-state').textContent='';updateData();
}
function mutate(kind){
 const next=structuredClone(state.input);next.mode='active';
 let exercise=next.exercises.find(e=>e.muscleGroup==='chest');
 if(kind==='remove'){
   const last=exercise?.sets.findLast(s=>s.completed&&!s.deleted&&s.isWarmup===false);
   if(!last){$('edit-state').textContent='There is no completed chest working set to remove.';return;}
   last.deleted=true;$('edit-state').textContent='Removed the last completed chest working set.';
 }else{
   if(!exercise){exercise={muscleGroup:'chest',sets:[]};next.exercises.push(exercise);}
   const pending=exercise.sets.find(s=>!s.completed&&!s.deleted&&s.isWarmup===false);
   if(pending)pending.completed=true;else exercise.sets.push({completed:true,isWarmup:false,deleted:false});
   $('edit-state').textContent='Completed one synthetic chest working set.';
 }
 state.history.push(state.input);state.input=next;updateData();
}
function hold(yaw,view='manual'){
 state.paused=true;state.yaw=yaw;state.view=view;loop.reconcile();motionLabels();draw();
}
function selectView(view){hold(view==='front'?0:Math.PI,view);}
$('motion').addEventListener('click',()=>{state.paused=!state.paused;state.view='manual';motionLabels();loop.reconcile();});
for(const view of views){
 let drag=null;
 view.canvas.addEventListener('pointerdown',event=>{if(!state.ready||event.button!==0)return;drag={id:event.pointerId,x:event.clientX,y:event.clientY,yaw:state.yaw,locked:false};});
 view.canvas.addEventListener('pointermove',event=>{
  if(!drag||event.pointerId!==drag.id)return;
  const dx=event.clientX-drag.x,dy=event.clientY-drag.y;
  if(!drag.locked){if(Math.abs(dy)>8&&Math.abs(dy)>Math.abs(dx)){drag=null;return;}if(Math.abs(dx)<8)return;drag.locked=true;view.canvas.setPointerCapture(event.pointerId);}
  hold(drag.yaw+dx*.009);
 });
 const end=()=>{drag=null;};view.canvas.addEventListener('pointerup',end);view.canvas.addEventListener('pointercancel',end);view.canvas.addEventListener('lostpointercapture',end);
 view.canvas.addEventListener('keydown',event=>{
  if(!state.ready)return;
  if(event.key==='ArrowLeft'||event.key==='ArrowRight'){event.preventDefault();hold(state.yaw+(event.key==='ArrowLeft'?-1:1)*Math.PI/18);}
  if(event.key==='Home'){event.preventDefault();selectView('front');}
 });
 view.canvas.addEventListener('renderfailure',()=>failArtwork(new Error('Graphics context lost')));
 new ResizeObserver(()=>{if(view.visible)draw();}).observe(view.canvas.parentElement);
}
const observer=new IntersectionObserver(entries=>{
 for(const entry of entries){const view=views.find(v=>v.canvas.parentElement===entry.target);view.visible=entry.isIntersecting;}
 state.visible=views.some(v=>v.visible);draw();loop.reconcile();
},{threshold:.01});
for(const view of views)observer.observe(view.canvas.parentElement);
document.addEventListener('visibilitychange',()=>{state.hidden=document.hidden;loop.reconcile();if(!state.hidden)draw();});
media.addEventListener('change',()=>{state.reduced=media.matches;motionLabels();loop.reconcile();draw();});
window.addEventListener('pagehide',()=>{state.hidden=true;loop.stop();});
window.addEventListener('pageshow',()=>{state.hidden=document.hidden;loop.reconcile();draw();});
$('theme').addEventListener('click',()=>{
 state.theme=state.theme==='dark'?'light':'dark';document.documentElement.dataset.theme=state.theme;
 $('theme').textContent=state.theme==='dark'?'Light theme':'Dark theme';if(state.input)updateData();else draw();
});
for(const button of document.querySelectorAll('[data-view]'))button.addEventListener('click',()=>selectView(button.dataset.view));
$('fixture').addEventListener('change',()=>selectFixture($('fixture').value));
$('complete').addEventListener('click',()=>mutate('complete'));
$('remove').addEventListener('click',()=>mutate('remove'));
$('undo').addEventListener('click',()=>{if(!state.history.length)return;state.input=state.history.pop();$('edit-state').textContent='Restored the previous synthetic workout sets.';updateData();});
async function loadArtwork(){
 $('retry').hidden=true;
 try{
   const fonts=await document.fonts.load('400 10px "Space Mono"');if(!fonts.length)throw new Error('Local character font unavailable');
   mesh=mesh||await loadMesh();
   for(const view of views){view.renderer?.dispose();view.renderer=new VolumeRenderer(view.canvas,mesh,view.compact);view.canvas.hidden=false;view.fallback.hidden=true;}
   state.ready=true;state.failed=false;
   for(const button of document.querySelectorAll('[data-view]'))button.disabled=false;
   motionLabels();draw();loop.reconcile();
 }catch(error){failArtwork(error);}
}
$('retry').addEventListener('click',loadArtwork);
$('render-mode').addEventListener('change',()=>{state.renderMode=$('render-mode').value;$('region-legend').hidden=state.renderMode!=='regions';draw();});
function sorted(value){if(Array.isArray(value))return value.map(sorted);if(value&&typeof value==='object')return Object.fromEntries(Object.keys(value).sort().map(k=>[k,sorted(value[k])]));return value;}
async function initialize(){
 $('theme').disabled=false;
 try{
   const response=await fetch('assets/body_workload_cases.json');if(!response.ok)throw new Error('Workout examples unavailable');
   fixtures=await response.json();
   for(const c of fixtures.cases)if(JSON.stringify(sorted(calculateWorkload(c)))!==JSON.stringify(sorted(c.expected)))throw new Error(`Calculator contract mismatch: ${c.id}`);
   $('fixture').replaceChildren(...fixtures.cases.map(c=>{const option=document.createElement('option');option.value=c.id;option.textContent=fixtureLabels[c.id]||c.id;return option;}));
   $('fixture').disabled=false;selectFixture('planned-resolved-eight');
 }catch(error){
   $('coverage').textContent='Workout examples unavailable. Reload this page to retry. No workload values can be shown.';
   $('compact-counts').textContent='Values unavailable';$('compact-total').textContent='—';$('compact-coverage').textContent='Workout examples unavailable.';
   console.error('Body map inputs:',error.message);
 }
 await loadArtwork();
}
// Read-only synthetic diagnostics for the coordinator's bounded checkpoint.
window.bodyGlbStudy={get state(){return {...state,input:structuredClone(state.input),result:structuredClone(state.result),history:state.history.length,scheduled:loop.handle!==null,visibleViews:views.map(v=>v.visible),mesh:mesh?{vertices:mesh.manifest.vertices,triangles:mesh.manifest.triangles}:null,draws:views.map(v=>v.renderer?.drawCount||0),glyphs:views.map(v=>v.renderer?.glyphCount||0)};}};
initialize();
