#!/usr/bin/env node
// Caller-selected private runtime assets only; no model data is saved here.
import assert from 'node:assert/strict';
import fs from 'node:fs';import path from 'node:path';import {createHash} from 'node:crypto';
import {balancePoint,fullerMesh,physiqueScale,bodyFit} from '../geometry.js';
assert.equal(process.argv.length,4,'Usage: node check-geometry.mjs --assets /private/assets');
assert.equal(process.argv[2],'--assets');
const directory=path.resolve(process.argv[3]),manifest=JSON.parse(fs.readFileSync(path.join(directory,'body.mesh.json')));
const bytes=fs.readFileSync(path.join(directory,'body.mesh.bin'));
const hash=value=>createHash('sha256').update(value).digest('hex'),sourceHash=hash(bytes);
assert.equal(sourceHash,manifest.sha256);
const types={'<f4':Float32Array,'<u4':Uint32Array,'|u1':Uint8Array},source={manifest};
for(const [name,a] of Object.entries(manifest.attributes))source[name]=new types[a.type](bytes.buffer,bytes.byteOffset+a.byteOffset,a.count);
const mesh=fullerMesh(source),repeat=fullerMesh(source);
assert.deepEqual(mesh.positions,repeat.positions);assert.deepEqual(mesh.normals,repeat.normals);
for(const name of ['indices','uv','regions','manifest'])assert.equal(mesh[name],source[name]);
const dot=(a,b)=>a.reduce((s,v,i)=>s+v*b[i],0),sub=(a,b)=>a.map((v,i)=>v-b[i]);
const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
const at=(array,i)=>Array.from(array.subarray(i*3,i*3+3));
const mul=(j,v)=>[0,1,2].map(row=>dot(j.slice(row*3,row*3+3),v)*physiqueScale[row]);
const seams=new Map(),bounds=[[Infinity,Infinity,Infinity],[-Infinity,-Infinity,-Infinity]];
let duplicateCount=0,maxDerivativeError=0,maxNormalError=0,maxDistortion=0,minDet=Infinity,maxDet=0,maxDisplacement=0,radius=0;
for(let i=0;i<manifest.vertices;i++){
 const p=at(source.positions,i),q=at(mesh.positions,i),n=at(source.normals,i),mappedNormal=at(mesh.normals,i);
 const {jacobian:j}=balancePoint(...p),numeric=Array(9),h=1e-6;
 for(let axis=0;axis<3;axis++){
  const plus=[...p],minus=[...p];plus[axis]+=h;minus[axis]-=h;
  const a=balancePoint(...plus).position,b=balancePoint(...minus).position;
  for(let row=0;row<3;row++)numeric[row*3+axis]=(a[row]-b[row])/(2*h);
 }
 maxDerivativeError=Math.max(maxDerivativeError,...j.map((v,k)=>Math.abs(v-numeric[k])));
 const tangent=cross(n,Math.abs(n[0])<.8?[1,0,0]:[0,1,0]);
 for(const t of [tangent,cross(n,tangent)]){
  const transported=mul(numeric,t);
  maxNormalError=Math.max(maxNormalError,Math.abs(dot(mappedNormal,transported))/Math.hypot(...transported));
 }
 assert.ok(Math.abs(Math.hypot(...mappedNormal)-1)<1e-7);
 const det=j[0]*j[8];minDet=Math.min(minDet,det);maxDet=Math.max(maxDet,det);
 // Relative to the accepted scaled body: S J S^-1. Its Frobenius
 // distance from identity bounds the relative singular-value changes.
 maxDistortion=Math.max(maxDistortion,Math.hypot(...j.map((v,k)=>v*physiqueScale[Math.floor(k/3)]/physiqueScale[k%3]-(k%4===0?1:0))));
 maxDisplacement=Math.max(maxDisplacement,Math.hypot(...q.map((v,k)=>v-p[k]*physiqueScale[k])));
 assert.equal(q[1],p[1]);
 const reflected=balancePoint(-p[0],p[1],p[2]).position,forward=balancePoint(...p).position;
 assert.ok(reflected.every((v,k)=>v===(k===0?-forward[k]:forward[k])));
 if(p[1]<=.04||p[1]>=.72||Math.abs(p[0])>=.4&&p[1]<=.12)for(let k=0;k<3;k++)assert.equal(q[k],Math.fround(p[k]*physiqueScale[k]),'Preserved lower body, head/neck and hands');
 const key=p.join(',');if(seams.has(key)){assert.deepEqual(q,at(mesh.positions,seams.get(key)));duplicateCount++;}else seams.set(key,i);
 for(let k=0;k<3;k++){assert.ok(Number.isFinite(q[k]));bounds[0][k]=Math.min(bounds[0][k],q[k]);bounds[1][k]=Math.max(bounds[1][k],q[k]);}
 radius=Math.max(radius,Math.hypot(q[0],q[2]));
}
assert.ok(minDet>.9&&maxDet<1.25,'Small positive volume change on actual vertices');
assert.ok(maxDistortion<.3,'Actual-mesh singular values stay within 0.7–1.3 of the accepted body');
assert.ok(maxDerivativeError<2e-8&&maxNormalError<1e-7,'Independent actual-vertex differential/normal checks');
assert.ok(maxDisplacement<.02,'Additional displacement below one percent of full source height');
assert.deepEqual(mesh.bounds,bounds);assert.equal(mesh.radius,radius);
// Compare every nondegenerate finite triangle with its local, analytically
// transported orientation. Tiny source triangles are reported, never repaired.
let tinyTriangles=0,minOrientationCosine=1,minAreaRatio=Infinity,maxAreaRatio=0,sliverOutliers=0;
for(let i=0;i<source.indices.length;i+=3){
 const ids=Array.from(source.indices.subarray(i,i+3)),p=ids.map(id=>at(source.positions,id)),q=ids.map(id=>at(mesh.positions,id));
 const a=sub(p[1],p[0]),b=sub(p[2],p[0]),before=cross(a,b),after=cross(sub(q[1],q[0]),sub(q[2],q[0]));
 if(Math.hypot(...before)<1e-12){tinyTriangles++;continue;}
 const centroid=[0,1,2].map(k=>(p[0][k]+p[1][k]+p[2][k])/3),j=balancePoint(...centroid).jacobian;
 const expected=cross(mul(j,a),mul(j,b)),cosine=dot(expected,after)/(Math.hypot(...expected)*Math.hypot(...after));
 minOrientationCosine=Math.min(minOrientationCosine,cosine);
 const accepted=cross(a.map((v,k)=>v*physiqueScale[k]),b.map((v,k)=>v*physiqueScale[k]));
 const ratio=Math.hypot(...after)/Math.hypot(...accepted);minAreaRatio=Math.min(minAreaRatio,ratio);maxAreaRatio=Math.max(maxAreaRatio,ratio);
 if(cosine<.98||ratio>1.5||ratio<.65){
  // Finite chords through a curved field and Float32 rounding can dominate
  // a pre-existing sliver's tiny altitude. Still require positive orientation
  // and an altitude below 1% of its longest edge for these outliers.
  const longest=Math.max(Math.hypot(...a),Math.hypot(...b),Math.hypot(...sub(p[2],p[1])));
  assert.ok(Math.hypot(...before)/(longest*longest)<.01,'Distortion outliers are confined to pre-existing sliver triangles');sliverOutliers++;
 }
 assert.ok(cosine>0,'No finite-triangle orientation reversal');
}
// Radial extent is the exact all-yaw supremum of horizontal/depth projection,
// so these inequalities cover every yaw, not just a finite set of views.
for(const aspect of [128/212,512/640]){
 const fit=bodyFit(mesh,aspect);
 assert.ok(radius*fit/aspect<=.9600001&&mesh.halfHeight*fit<=.9600001);
 assert.equal(mesh.radius,radius,'Depth clip includes the entire all-yaw extent');
}
function section(y,lowX,highX){
 const before=[[Infinity,Infinity],[-Infinity,-Infinity]],after=[[Infinity,Infinity],[-Infinity,-Infinity]];let count=0;
 for(let i=0;i<manifest.vertices;i++){
  const p=at(source.positions,i);if(Math.abs(p[1]-y)>.002||p[0]<lowX||p[0]>highX)continue;count++;
  for(const [array,out] of [[source.positions,before],[mesh.positions,after]])for(const [k,axis] of [0,2].entries()){
   const value=array[i*3+axis]*(array===source.positions?physiqueScale[axis]:1);out[0][k]=Math.min(out[0][k],value);out[1][k]=Math.max(out[1][k],value);
  }
 }
 assert.ok(count>100);return {vertices:count,widthRatio:(after[1][0]-after[0][0])/(before[1][0]-before[0][0]),depthRatio:(after[1][1]-after[0][1])/(before[1][1]-before[0][1])};
}
const sections={shoulders:section(.60,-1,1),rightDeltoid:section(.60,.18,1),rightUpperArm:section(.44,.25,1),chest:section(.50,-.18,.18),waist:section(.20,-.25,.25)};
assert.ok(sections.shoulders.widthRatio>1.01&&sections.shoulders.widthRatio<1.05);
assert.ok(sections.rightUpperArm.widthRatio>1.03&&sections.rightUpperArm.widthRatio<1.10);
assert.ok(sections.chest.depthRatio>1.015&&sections.chest.depthRatio<1.04);
assert.ok(sections.waist.widthRatio>.965&&sections.waist.widthRatio<.985);
assert.equal(hash(bytes),sourceHash,'Source bytes unchanged');
console.log(JSON.stringify({result:'PASS',vertices:manifest.vertices,triangles:manifest.triangles,sourceSha256:sourceHash,duplicateCount,maxDerivativeError,maxNormalError,minDet,maxDet,maxDistortion,maxDisplacement,tinyTriangles,sliverOutliers,minOrientationCosine,minAreaRatio,maxAreaRatio,bounds,radius,sections},null,2));
