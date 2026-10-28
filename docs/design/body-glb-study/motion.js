export const TURN_MS=52000;
export function canAnimate(state){return state.ready&&!state.failed&&!state.paused&&!state.reduced&&!state.hidden&&state.visible;}
export function advanceYaw(yaw,elapsed){return (yaw+Math.max(0,Math.min(elapsed,100))*Math.PI*2/TURN_MS)%(Math.PI*2);}
/** At most one frame; disabling clears the time anchor, never catches up. */
export class MotionLoop{
 constructor(state,draw,{request:request=callback=>requestAnimationFrame(callback),cancel:cancel=handle=>cancelAnimationFrame(handle)}={}){this.state=state;this.draw=draw;this.request=request;this.cancel=cancel;this.handle=null;this.previous=null;this.tick=this.tick.bind(this);}
 reconcile(){if(canAnimate(this.state)){if(this.handle===null)this.handle=this.request(this.tick);}else this.stop();}
 stop(){if(this.handle!==null)this.cancel(this.handle);this.handle=null;this.previous=null;}
 tick(now){this.handle=null;if(!canAnimate(this.state)){this.previous=null;return;}if(this.previous!==null)this.state.yaw=advanceYaw(this.state.yaw,now-this.previous);this.previous=now;this.draw();this.reconcile();}
}
