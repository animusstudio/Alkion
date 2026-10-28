export const TURN_MS=52000;
export function canAnimate(state){return state.ready&&!state.failed&&!state.paused&&!state.reduced&&!state.hidden&&state.visible;}
export function canDraw(state){return state.ready&&!state.failed&&!state.hidden&&state.visible;}
export function advanceYaw(yaw,elapsed){return (yaw+Math.max(0,Math.min(elapsed,100))*Math.PI*2/TURN_MS)%(Math.PI*2);}
/** One frame for both invalidation and autoplay. Manual turns work while paused. */
export class MotionLoop{
 constructor(state,draw,{request:request=callback=>requestAnimationFrame(callback),cancel:cancel=handle=>cancelAnimationFrame(handle)}={}){this.state=state;this.draw=draw;this.request=request;this.cancel=cancel;this.handle=null;this.previous=null;this.dirty=false;this.tick=this.tick.bind(this);}
 invalidate(){this.dirty=true;this.reconcile();}
 reconcile(){
  if(!canDraw(this.state)){this.stop();return;}
  const animate=canAnimate(this.state);if(!animate)this.previous=null;
  if(this.dirty||animate){if(this.handle===null)this.handle=this.request(this.tick);}else this.stop();
 }
 stop(){if(this.handle!==null)this.cancel(this.handle);this.handle=null;this.previous=null;}
 tick(now){
  this.handle=null;if(!canDraw(this.state)){this.previous=null;return;}
  const animate=canAnimate(this.state);
  if(animate&&this.previous!==null)this.state.yaw=advanceYaw(this.state.yaw,now-this.previous);
  this.previous=animate?now:null;
  if(this.dirty||animate){this.dirty=false;this.draw();}
  this.reconcile();
 }
}
