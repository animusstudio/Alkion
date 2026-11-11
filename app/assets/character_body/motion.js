// One slow intro turn when a view first draws, then still (owner choice,
// 2026-11-11): idle artwork requests no frames at all. A full turn takes 8 s on
// a sine ease-in-out, so it leaves and settles at rest and peaks at π/2 × the
// mean speed (about 71°/s); the figure holds still within seconds of appearing.
export const INTRO_MS=8000;
export function canAnimate(state){return state.ready&&!state.failed&&!state.paused&&!state.reduced&&!state.hidden&&state.visible;}
export function canDraw(state){return state.ready&&!state.failed&&!state.hidden&&state.visible;}
/** Yaw after [progress] (0..1) of the intro: one full turn from [from], ending exactly there. */
export function introYaw(from,progress){const p=Math.max(0,Math.min(1,progress));return p>=1?from:(from+Math.PI*(1-Math.cos(Math.PI*p)))%(Math.PI*2);}
/**
 * One RAF scheduler for invalidation and the intro turn; manual turns work while
 * paused. arm() asks for one intro: the next drawn frame starts it at the current
 * yaw when it may animate, and otherwise drops it (reduced motion, paused). A
 * running intro ends for good when the view hides, pauses, turns reduced or
 * stops; it never resumes or catches up. Otherwise frames run only while dirty.
 */
export class MotionLoop{
 constructor(state,draw,{request:request=callback=>requestAnimationFrame(callback),cancel:cancel=handle=>cancelAnimationFrame(handle)}={}){this.state=state;this.draw=draw;this.request=request;this.cancel=cancel;this.handle=null;this.dirty=false;this.armed=false;this.intro=null;this.tick=this.tick.bind(this);}
 get turning(){return this.intro!==null;}
 arm(){this.armed=true;}
 disarm(){this.armed=false;this.intro=null;}
 invalidate(){this.dirty=true;this.reconcile();}
 reconcile(){
  if(!canDraw(this.state)){this.stop();return;}
  if(this.intro&&!canAnimate(this.state))this.intro=null;
  if(this.dirty||this.armed||this.intro){if(this.handle===null)this.handle=this.request(this.tick);}else this.stop();
 }
 stop(){if(this.handle!==null)this.cancel(this.handle);this.handle=null;this.intro=null;}
 tick(now){
  this.handle=null;if(!canDraw(this.state)){this.intro=null;return;}
  const animate=canAnimate(this.state),intro=this.intro;
  if(this.armed){this.armed=false;if(animate){this.intro={from:this.state.yaw,elapsed:0,previous:now};this.dirty=true;}}
  else if(intro&&animate){
   // A stalled frame advances at most 100 ms: the turn never jumps.
   intro.elapsed+=Math.max(0,Math.min(now-intro.previous,100));intro.previous=now;
   this.state.yaw=introYaw(intro.from,intro.elapsed/INTRO_MS);if(intro.elapsed>=INTRO_MS)this.intro=null;this.dirty=true;
  }else this.intro=null;
  if(this.dirty){this.dirty=false;this.draw();}
  this.reconcile();
 }
}
