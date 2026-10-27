#!/usr/bin/env node
// Verify the derived pose separately from the unchanged source conversion.
import assert from 'node:assert/strict';
import fs from 'node:fs';import path from 'node:path';import {createHash} from 'node:crypto';
import {posedMesh,posePoint,transportNormal} from '../pose-geometry.js';
import {bodyFit} from '../geometry.js';
assert.equal(process.argv.length,4,'Usage: node check-pose.mjs --assets /private/assets');assert.equal(process.argv[2],'--assets');
const directory=path.resolve(process.argv[3]),manifest=JSON.parse(fs.readFileSync(path.join(directory,'body.mesh.json')));
const bytes=fs.readFileSync(path.join(directory,'body.mesh.bin')),hash=value=>createHash('sha256').update(value).digest('hex'),sourceHash=hash(bytes);
assert.equal(sourceHash,manifest.sha256);
const types={'<f4':Float32Array,'<u4':Uint32Array,'|u1':Uint8Array},source={manifest};
for(const [name,a] of Object.entries(manifest.attributes))source[name]=new types[a.type](bytes.buffer,bytes.byteOffset+a.byteOffset,a.count);
const mesh=posedMesh(source),again=posedMesh(source);
assert.deepEqual(mesh.positions,again.positions);assert.deepEqual(mesh.normals,again.normals);assert.equal(hash(bytes),sourceHash);
for(const name of ['indices','uv','regions','manifest'])assert.equal(mesh[name],source[name]);
assert.notEqual(mesh.positions,source.positions);assert.notEqual(mesh.normals,source.normals);
const point=(array,id)=>Array.from(array.subarray(id*3,id*3+3));
const sub=(a,b)=>a.map((v,k)=>v-b[k]),dot=(a,b)=>a.reduce((s,v,k)=>s+v*b[k],0);
const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
const determinant=j=>j[0]*(j[4]*j[8]-j[5]*j[7])-j[1]*(j[3]*j[8]-j[5]*j[6])+j[2]*(j[3]*j[7]-j[4]*j[6]);
const multiply=(j,v)=>[0,1,2].map(k=>dot(j.slice(k*3,k*3+3),v));
let maxJacobianError=0,maxNormalTangentError=0;
function checkDifferential(p,n){
 const result=posePoint(...p),numeric=Array(9).fill(0),h=1e-6;
 for(let axis=0;axis<3;axis++){
  const a=[...p],b=[...p];a[axis]+=h;b[axis]-=h;
  const pa=posePoint(...a).position,pb=posePoint(...b).position;
  for(let row=0;row<3;row++)numeric[row*3+axis]=(pa[row]-pb[row])/(2*h);
 }
 maxJacobianError=Math.max(maxJacobianError,...numeric.map((v,k)=>Math.abs(v-result.jacobian[k])));
 assert.ok(determinant(result.jacobian)>0,'Positive local orientation');
 const normal=transportNormal(result.jacobian,n),axis=Math.abs(n[0])<.9?[1,0,0]:[0,1,0];
 const t=cross(n,axis),u=cross(n,t);
 maxNormalTangentError=Math.max(maxNormalTangentError,Math.abs(dot(normal,multiply(numeric,t))),Math.abs(dot(normal,multiply(numeric,u))));
 const reflection=posePoint(-p[0],p[1],p[2]).position;
 assert.ok(Math.hypot(reflection[0]+result.position[0],reflection[1]-result.position[1],reflection[2]-result.position[2])<1e-15,'Bilateral symmetry');
}
// Transition interiors, support boundaries, X=0, and representative surface points.
for(const y of [-.125,-.12,-.04,.055,.13,.23,.235,.4,.5,.6,.7])for(const x of [0,.00001,.0175,.035,.10,.13,.17,.20,.22,.24,.30,.5])for(const z of [-.16,-.12,-.07,-.02,.1])checkDifferential([x,y,z],[.3,.4,Math.sqrt(.75)]);
for(const r of [.015,.045,.075,.1,.8])for(const u of [0,.04,.18,.32,1])for(const sign of [-1,1])checkDifferential([.225+r*u,.6+sign*r*Math.sqrt(1-u*u),0],[.3,.4,Math.sqrt(.75)]);
checkDifferential([.225,.6,0],[.3,.4,Math.sqrt(.75)]);
const bounds=[[Infinity,Infinity,Infinity],[-Infinity,-Infinity,-Infinity]],seams=new Map();
const gapBands=Array.from({length:30},(_,i)=>({y:i*.01,arm:Infinity,torso:0}));
let radius=0,duplicateCount=0,minDet=Infinity,maxDet=0,maxNormalLengthError=0,maxGluteGain=0,rigidVertices=0,handVertices=0,maxRigidRadiusError=0,unchangedVertices=0;
for(let id=0;id<manifest.vertices;id++){
 const p=point(source.positions,id),q=point(mesh.positions,id),n=point(mesh.normals,id),mapped=posePoint(...p),det=determinant(mapped.jacobian);
 assert.ok(det>0&&Number.isFinite(det));minDet=Math.min(minDet,det);maxDet=Math.max(maxDet,det);
 assert.deepEqual(q,mapped.position.map(Math.fround));assert.ok(q.every(Number.isFinite)&&n.every(Number.isFinite));
 maxNormalLengthError=Math.max(maxNormalLengthError,Math.abs(Math.hypot(...n)-1));
 maxGluteGain=Math.max(maxGluteGain,p[2]-q[2]);
 if(p.every((v,k)=>v===q[k]))unchangedVertices++;
 if(mapped.armWeight===1){
  rigidVertices++;const pivot=[Math.sign(p[0])*.225,.60,0];
  maxRigidRadiusError=Math.max(maxRigidRadiusError,Math.abs(Math.hypot(...sub(p,pivot))-Math.hypot(...sub(q,pivot))));
 }
 if(p[1]<=.15&&p[1]>=-.1&&Math.abs(p[0])>.46){handVertices++;assert.equal(mapped.armWeight,1,'Both complete hands/fingers share the rigid arm pose');}
 const band=gapBands[Math.floor(q[1]/.01)];
 if(band&&Math.abs(p[0])>.25&&p[1]<.4)band.arm=Math.min(band.arm,Math.abs(q[0]));
 if(band&&Math.abs(p[0])<.225)band.torso=Math.max(band.torso,Math.abs(q[0]));
 const key=p.join(',');if(seams.has(key)){duplicateCount++;assert.deepEqual(q,seams.get(key),'Every coincident source vertex stays coincident');}else seams.set(key,q);
 for(let k=0;k<3;k++){bounds[0][k]=Math.min(bounds[0][k],q[k]);bounds[1][k]=Math.max(bounds[1][k],q[k]);}
 radius=Math.max(radius,Math.hypot(q[0],q[2]));
 if(id%83===0)checkDifferential(p,point(source.normals,id));
 // Central torso/chest, head/neck, anterior pelvis, and legs outside the
 // posterior glute support retain their positions, including Float32 storage.
 if((Math.abs(p[0])<.14&&p[1]>.25)||p[1]>.72||p[1]<-.125||(Math.abs(p[0])<.22&&p[1]<.24&&p[2]>=-.02))assert.deepEqual(q,p);
}
assert.ok(maxJacobianError<1e-7&&maxNormalTangentError<1e-7);assert.ok(maxNormalLengthError<1e-7&&maxRigidRadiusError<1e-7);
assert.ok(maxGluteGain>.009&&maxGluteGain<=.0100001);assert.ok(rigidVertices>0&&handVertices>0);
const minLowerArmTorsoGap=Math.min(...gapBands.map(b=>{assert.ok(Number.isFinite(b.arm)&&b.torso>0);return b.arm-b.torso;}));
assert.ok(minLowerArmTorsoGap>.05,'Lower-arm/torso projected separation stays open');
assert.deepEqual(mesh.bounds,bounds);assert.equal(mesh.radius,radius);
for(const aspect of [128/212,512/640]){
 const fit=bodyFit(mesh,aspect);
 assert.ok(radius*fit/aspect<=.9600001&&mesh.halfHeight*fit<=.9600001,'Radial bound contains every continuous yaw and view depth');
}
// Account for EVERY source triangle, including exact zero and finite slivers.
// Compare finite chords to the independently differentiated centroid normal.
const triangleStats={total:0,sourceZero:0,posedZero:0,reversedChord:0,rigid:0,maxRigidEdgeError:0,minChordCosine:1};
const outliers=[];
for(let at=0;at<mesh.indices.length;at+=3){
 const ids=Array.from(mesh.indices.subarray(at,at+3)),p=ids.map(id=>point(source.positions,id)),q=ids.map(id=>point(mesh.positions,id));
 const a=sub(p[1],p[0]),b=sub(p[2],p[0]),qa=sub(q[1],q[0]),qb=sub(q[2],q[0]),old=cross(a,b),now=cross(qa,qb);
 const area=Math.hypot(...old),newArea=Math.hypot(...now);triangleStats.total++;
 assert.ok(Number.isFinite(area)&&Number.isFinite(newArea));
 if(area===0)triangleStats.sourceZero++;if(newArea===0)triangleStats.posedZero++;
 if(area>0&&newArea>0){
  const centroid=[0,1,2].map(k=>(p[0][k]+p[1][k]+p[2][k])/3),expected=transportNormal(posePoint(...centroid).jacobian,old);
  const cosine=dot(expected,now)/newArea;triangleStats.minChordCosine=Math.min(triangleStats.minChordCosine,cosine);
  if(cosine<=0){
   triangleStats.reversedChord++;
   const longestEdge=Math.max(Math.hypot(...a),Math.hypot(...b),Math.hypot(...sub(p[2],p[1])));
   // This is a real finite-chord warning, not an area exclusion or a claim of
   // unchanged winding. Local differential orientation was checked above.
   outliers.push({triangle:at/3,sourceDoubleArea:area,posedDoubleArea:newArea,longestEdge,slenderness:area/(longestEdge*longestEdge),cosine});
  }
 }
 if(p.every(v=>posePoint(...v).armWeight===1)&&p.every(v=>Math.sign(v[0])===Math.sign(p[0][0]))){
  triangleStats.rigid++;
  for(const [i,j] of [[0,1],[1,2],[2,0]])triangleStats.maxRigidEdgeError=Math.max(triangleStats.maxRigidEdgeError,Math.abs(Math.hypot(...sub(p[i],p[j]))-Math.hypot(...sub(q[i],q[j]))));
 }
}
assert.equal(triangleStats.total,manifest.triangles);assert.ok(triangleStats.maxRigidEdgeError<1e-7);
assert.equal(hash(bytes),sourceHash);
console.log(JSON.stringify({result:outliers.length?'FAIL':'PASS',vertices:manifest.vertices,sourceSha256:manifest.sourceSha256,binarySha256:sourceHash,positionsSha256:hash(mesh.positions),normalsSha256:hash(mesh.normals),bounds,radius,duplicateCount,unchangedVertices,minDet,maxDet,maxGluteGain,rigidVertices,handVertices,minLowerArmTorsoGap,maxRigidRadiusError,maxJacobianError,maxNormalTangentError,maxNormalLengthError,triangleStats,outliers},null,2));
// No finite-chord exception, including the smallest source slivers.
assert.equal(triangleStats.posedZero,triangleStats.sourceZero);
assert.equal(outliers.length,0,'Every nonzero source face must retain positive finite-chord orientation');
