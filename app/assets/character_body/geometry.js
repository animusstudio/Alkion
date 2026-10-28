// Keep the accepted whole-body fullness; balance is a small, separate source-
// position field before this scale and yaw. It never reads normals, UVs or IDs.
export const physiqueScale=Object.freeze([1.10,1,1.15]);

// Quintic ramps have zero first/second derivatives at both ends. Their broad
// overlap keeps anatomical connections continuous, including duplicated seams.
function ramp(value,low,high){
 if(value<=low)return [0,0];if(value>=high)return [1,0];
 const t=(value-low)/(high-low);
 return [t*t*t*(10+t*(-15+6*t)),30*t*t*(1-t)*(1-t)/(high-low)];
}
function band(value,low,rise,fall,high){
 const [a,da]=ramp(value,low,rise),[b,db]=ramp(value,fall,high);
 return [a*(1-b),da*(1-b)-a*db];
}

// The normalized source has shoulders near .58 Y, waist near .20 and wrists
// below .12. Broad torso/arm fields blend across the armpit; no muscle islands
// are inflated. X reflection is exact, and Y/pose height never changes.
export function balancePoint(x,y,z){
 const side=Math.sign(x),u=Math.abs(x);
 const [outer,outerU]=ramp(u,.17,.27),[edge,edgeU]=ramp(u,.22,.31);
 const [armY,armDy]=band(y,.12,.24,.57,.72);
 const arm=outer*armY,armX=side*outerU*armY,armDyAll=outer*armDy;
 const [chestY,chestDy]=band(y,.29,.44,.58,.71);
 const [chestEdge,chestEdgeU]=ramp(u,.15,.28);
 const chest=(1-chestEdge)*chestY,chestX=-side*chestEdgeU*chestY,chestDyAll=(1-chestEdge)*chestDy;
 const [waistY,waistDy]=band(y,.04,.18,.23,.37);
 const waist=(1-edge)*waistY,waistX=-side*edgeU*waistY,waistDyAll=(1-edge)*waistDy;
 const torso=.025*chest-.03*waist;
 // Expand around the slanted arm axis, with a small outward shoulder gain
 // fading to zero before the wrist. Depth gain is around the arm's own center.
 const armAcross=Math.tanh((x-side*(.53-.5*y))/.1),armSlope=1-armAcross*armAcross;
 const armOffset=.008*(armAcross+side);
 const armDepth=.075*(z+.025);
 const px=x*(1+torso)+arm*armOffset;
 const pz=z*(1+.03*chest)+arm*armDepth;
 // J = [a b 0; 0 1 0; c d e], analytic derivatives of the same field.
 const a=1+torso+x*(.025*chestX-.03*waistX)+armX*armOffset+.08*armSlope*arm;
 const b=x*(.025*chestDyAll-.03*waistDyAll)+armDyAll*armOffset+.04*side*armSlope*arm;
 const c=.03*z*chestX+armX*armDepth;
 const d=.03*z*chestDyAll+armDyAll*armDepth;
 const e=1+.03*chest+.075*arm;
 return {position:[px,y,pz],jacobian:[a,b,0,0,1,0,c,d,e]};
}

export function fullerMesh(source){
 const positions=new Float32Array(source.positions.length),normals=new Float32Array(source.normals.length);
 const bounds=[[Infinity,Infinity,Infinity],[-Infinity,-Infinity,-Infinity]];
 let radius=0;
 for(let at=0;at<positions.length;at+=3){
  const {position,jacobian:j}=balancePoint(source.positions[at],source.positions[at+1],source.positions[at+2]);
  if(!(j[0]>0&&j[8]>0))throw new Error('Invalid body deformation');
  // First J^-T, then S^-T. The Y component includes the slanted blend's
  // shear; dividing by XYZ scales alone would give incorrect shoulder light.
  const bz=source.normals[at+2]/j[8],bx=(source.normals[at]-j[6]*bz)/j[0];
  const nx=bx/physiqueScale[0],ny=source.normals[at+1]-j[1]*bx-j[7]*bz,nz=bz/physiqueScale[2];
  const length=Math.hypot(nx,ny,nz);
  if(!Number.isFinite(length)||length===0)throw new Error('Invalid body normal');
  normals.set([nx/length,ny/length,nz/length],at);
  for(let axis=0;axis<3;axis++){
   positions[at+axis]=position[axis]*physiqueScale[axis];
   const value=positions[at+axis];
   if(!Number.isFinite(value))throw new Error('Invalid body position');
   bounds[0][axis]=Math.min(bounds[0][axis],value);bounds[1][axis]=Math.max(bounds[1][axis],value);
  }
  radius=Math.max(radius,Math.hypot(positions[at],positions[at+2]));
 }
 const halfHeight=Math.max(Math.abs(bounds[0][1]),Math.abs(bounds[1][1]));
 if(!(radius>0&&halfHeight>0))throw new Error('Invalid body extent');
 // Keep the original manifest and all identity/topology arrays unmodified.
 return {...source,positions,normals,bounds,radius,halfHeight};
}

// Tight radial extent fits every yaw without resizing during rotation. Both
// height and width have the existing 4% margin, including the compact card.
export function bodyFit(mesh,aspect){return Math.min(.96/mesh.halfHeight,.96*aspect/mesh.radius);}
