#!/usr/bin/env node
// Caller-selected converted source assets; no source geometry is stored here.
import assert from 'node:assert/strict';
import fs from 'node:fs';import path from 'node:path';import {createHash} from 'node:crypto';
import {sourceMesh} from '../source-geometry.js';
import {bodyFit} from '../geometry.js';
assert.equal(process.argv.length,4,'Usage: node check-source-geometry.mjs --assets /private/assets');assert.equal(process.argv[2],'--assets');
const directory=path.resolve(process.argv[3]),manifest=JSON.parse(fs.readFileSync(path.join(directory,'body.mesh.json')));
const bytes=fs.readFileSync(path.join(directory,'body.mesh.bin')),hash=value=>createHash('sha256').update(value).digest('hex'),sourceHash=hash(bytes);
assert.equal(sourceHash,manifest.sha256);
const types={'<f4':Float32Array,'<u4':Uint32Array,'|u1':Uint8Array},source={manifest};
for(const [name,a] of Object.entries(manifest.attributes))source[name]=new types[a.type](bytes.buffer,bytes.byteOffset+a.byteOffset,a.count);
assert.equal(source.positions.length,manifest.vertices*3);assert.equal(source.indices.length,manifest.triangles*3);
const mesh=sourceMesh(source);assert.deepEqual(sourceMesh(source),mesh);
for(const name of ['positions','normals','indices','uv','regions','manifest'])assert.equal(mesh[name],source[name],name+' has exact source identity');
const bounds=[[Infinity,Infinity,Infinity],[-Infinity,-Infinity,-Infinity]],seams=new Set();let radius=0,maxNormalLengthError=0,duplicateCount=0;
for(let at=0;at<mesh.positions.length;at+=3){
 const p=Array.from(mesh.positions.subarray(at,at+3)),key=p.join(',');
 if(seams.has(key))duplicateCount++;else seams.add(key);
 for(let k=0;k<3;k++){bounds[0][k]=Math.min(bounds[0][k],p[k]);bounds[1][k]=Math.max(bounds[1][k],p[k]);}
 radius=Math.max(radius,Math.hypot(p[0],p[2]));
 maxNormalLengthError=Math.max(maxNormalLengthError,Math.abs(Math.hypot(...mesh.normals.subarray(at,at+3))-1));
}
assert.ok(maxNormalLengthError<1e-7);assert.deepEqual(mesh.bounds,bounds);assert.deepEqual(mesh.bounds,manifest.bounds);assert.equal(mesh.radius,radius);
let zeroAreaTriangles=0,tinyNonzeroTriangles=0,minDoubleArea=Infinity,maxDoubleArea=0;
for(let i=0;i<mesh.indices.length;i+=3){
 const p=Array.from(mesh.indices.subarray(i,i+3),id=>{assert.ok(id<manifest.vertices);return Array.from(mesh.positions.subarray(id*3,id*3+3));});
 const a=p[1].map((v,k)=>v-p[0][k]),b=p[2].map((v,k)=>v-p[0][k]);
 const area=Math.hypot(a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]);
 assert.ok(Number.isFinite(area));if(area===0)zeroAreaTriangles++;else if(area<1e-14)tinyNonzeroTriangles++;
 minDoubleArea=Math.min(minDoubleArea,area);maxDoubleArea=Math.max(maxDoubleArea,area);
}
// Exact shared arrays mean every triangle and seam is the unchanged converted
// source, including any source degeneracy. There is no runtime deformation or
// normal transport to approximate, nor any triangle exclusion.
for(const aspect of [128/212,512/640]){
 const fit=bodyFit(mesh,aspect);
 assert.ok(radius*fit/aspect<=.9600001&&mesh.halfHeight*fit<=.9600001,'All-yaw framing and depth containment');
}
assert.equal(hash(bytes),sourceHash);
console.log(JSON.stringify({result:'PASS',mode:'unmodified-source',vertices:manifest.vertices,triangles:manifest.triangles,sourceSha256:manifest.sourceSha256,binarySha256:sourceHash,positionsSha256:hash(mesh.positions),normalsSha256:hash(mesh.normals),duplicateCount,maxNormalLengthError,zeroAreaTriangles,tinyNonzeroTriangles,minDoubleArea,maxDoubleArea,bounds,radius},null,2));
