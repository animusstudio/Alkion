import {sourceMesh} from './source-geometry.js';

// Female source coordinates: height two, +Y up, +Z anterior. These continuous
// position fields never consult UV islands. Keep the original buffers intact.
const armAngle=6*Math.PI/180,shoulderX=.225,shoulderY=.60;
function ramp(value,lo,hi){
 const t=(value-lo)/(hi-lo);
 if(t<=0)return [0,0];if(t>=1)return [1,0];
 return [t*t*t*(10+t*(-15+6*t)),30*t*t*(1-t)*(1-t)/(hi-lo)];
}
export function posePoint(x,y,z){
 const side=Math.sign(x),ax=Math.abs(x);
 // The angular blend lies at the shoulder/upper-arm attachment. Beyond it,
 // the entire arm, wrist and every finger share one exact rigid rotation.
 // Its angular derivative is bounded by 1.875/.28, so det(J) is at least
 // 1 - (6*pi/180)*1.875/.28 > .298. The radial fade adds no angular shear.
 // The .04 dead zone excludes even the source's outer calf/foot vertices.
 const lateral=ax-shoulderX,dy=y-shoulderY,r=Math.hypot(lateral,dy);
 const [angular,da]=ramp(r?lateral/r:0,.04,.32),[radial,dr]=ramp(r,.015,.075);
 const wx=r?da*radial*dy*dy/(r*r*r)+angular*dr*lateral/r:0;
 const wy=r?-da*radial*lateral*dy/(r*r*r)+angular*dr*dy/r:0;
 const w=angular*radial,angle=-side*armAngle*w;
 const c=Math.cos(angle),s=Math.sin(angle),dx=x-side*shoulderX;
 const rx=c*dx-s*dy,ry=s*dx+c*dy,tx=-armAngle*wx,ty=-side*armAngle*wy;
 // A restrained posterior-only field: preserve the central cleft, taper before
 // the outer hip, and meet the pelvis/thigh with zero first/second derivatives.
 const [inner,di]=ramp(ax,0,.035),[outer,dout]=ramp(ax,.13,.22),[front,df]=ramp(z,-.12,-.02);
 const t=(y-.055)/.18,b=Math.max(0,1-t*t),by=b*b*b,dby=b>0?-6*t*b*b/.18:0;
 const bx=inner*(1-outer),dbx=side*(di*(1-outer)-inner*dout),bz=1-front;
 const displacement=-.010*bx*by*bz;
 return {position:[w?side*shoulderX+rx:x,w?shoulderY+ry:y,z+displacement],
  jacobian:[c-ry*tx,-s-ry*ty,0,s+rx*tx,c+rx*ty,0,-.010*dbx*by*bz,-.010*bx*dby*bz,1+.010*bx*by*df],armWeight:w};
}
// Cofactor(J) n is det(J) J^-T n. Positive orientation makes normalization
// identical to inverse-transpose transport, including attachment derivatives.
export function transportNormal(j,n){
 const [a,b,c,d,e,f,g,h,i]=j,[x,y,z]=n;
 const nx=(e*i-f*h)*x+(f*g-d*i)*y+(d*h-e*g)*z;
 const ny=(c*h-b*i)*x+(a*i-c*g)*y+(b*g-a*h)*z;
 const nz=(b*f-c*e)*x+(c*d-a*f)*y+(a*e-b*d)*z;
 const length=Math.hypot(nx,ny,nz);
 if(!(length>0&&Number.isFinite(length)))throw new Error('Invalid posed normal');
 return [nx/length,ny/length,nz/length];
}
export function posedMesh(source){
 sourceMesh(source);
 const positions=new Float32Array(source.positions.length),normals=new Float32Array(source.normals.length);
 for(let at=0;at<positions.length;at+=3){
  const p=posePoint(...source.positions.subarray(at,at+3));
  positions.set(p.position,at);normals.set(transportNormal(p.jacobian,source.normals.subarray(at,at+3)),at);
 }
 // Measure the final Float32 buffers, not double-precision intermediate points.
 return sourceMesh({...source,positions,normals});
}
