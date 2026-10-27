#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {calculateWorkload, canonicalMuscles} from '../workload.js';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const read=name=>fs.readFileSync(path.join(root,name));
const fixtures=JSON.parse(read('assets/body_workload_cases.json'));
assert.deepEqual(fixtures.canonicalMuscles,canonicalMuscles);
const authoritative=path.resolve(root,'../../../app/test/fixtures/body_workload_cases.json');
assert.deepEqual(read('assets/body_workload_cases.json'),fs.readFileSync(authoritative),'Bundled golden fixtures must remain byte-identical to Dart fixtures');
for(const fixture of fixtures.cases){
  const before=JSON.stringify(fixture);
  assert.deepEqual(calculateWorkload(fixture),fixture.expected,fixture.id);
  assert.equal(JSON.stringify(fixture),before,'Calculator must not mutate authoritative inputs');
}
const live=structuredClone(fixtures.cases.find(c=>c.id==='active-before-first-set'));
const chest=live.exercises.find(e=>e.muscleGroup==='chest');
const pending=chest.sets.find(s=>!s.completed&&!s.deleted&&!s.isWarmup);
assert.ok(pending,'Live case has an authoritative pending chest set');
pending.completed=true;
assert.equal(calculateWorkload(live).muscles.chest.count,1,'Completion recomputes');
pending.deleted=true;
assert.equal(calculateWorkload(live).muscles.chest.count,0,'Removal recomputes');
pending.deleted=false;
assert.equal(calculateWorkload(live).muscles.chest.count,1,'Undo recomputes');
pending.isWarmup=true;
assert.equal(calculateWorkload(live).muscles.chest.count,0,'Editing to warmup recomputes');
pending.isWarmup=false;
const resumed=JSON.parse(JSON.stringify(live));
assert.deepEqual(calculateWorkload(resumed),calculateWorkload(live),'Resumed input recomputes identically');
const mesh=JSON.parse(read('assets/body.mesh.json'));
const provenance=JSON.parse(read('assets/provenance.json'));
assert.equal(mesh.version,1);assert.equal(mesh.positions.length,mesh.normals.length);
assert.equal(mesh.positions.length/3,provenance.vertices);
assert.equal(mesh.indices.length/3,provenance.triangles);
assert.equal(mesh.triangleRegions.length,provenance.triangles);
assert.equal(provenance.retainedGroup,'body');
// The sculpt must preserve the entire original continuous body, including
// head/hands/feet. No added primitive muscle shells or missing surface faces.
let sourceGroup='';
const sourceFaces=[];
for(const line of read('assets/makehuman-base.obj').toString().split('\n')){
  const fields=line.trim().split(/\s+/);
  if(fields[0]==='g')sourceGroup=fields[1];
  if(fields[0]==='f'&&sourceGroup==='body')sourceFaces.push(fields.slice(1).map(v=>Number(v.split('/')[0])-1));
}
const sourceIds=[...new Set(sourceFaces.flat())].sort((a,b)=>a-b);
const sourceLookup=new Map(sourceIds.map((id,i)=>[id,i]));
const sourceIndices=sourceFaces.flatMap(face=>face.slice(1,-1).flatMap((_,j)=>[face[0],face[j+1],face[j+2]].map(id=>sourceLookup.get(id))));
assert.equal(mesh.positions.length/3,sourceIds.length,'All original body vertices retained');
assert.deepEqual(mesh.indices,sourceIndices,'Authored sculpt preserves exact original body topology');
assert.ok(Object.keys(provenance.sourceGroups).some(g=>g.startsWith('helper-')),'Source group audit retained');
for(const coordinate of [...mesh.positions,...mesh.normals])assert.ok(Number.isFinite(coordinate));
for(const index of mesh.indices)assert.ok(Number.isInteger(index)&&index>=0&&index<provenance.vertices);
for(const part of mesh.triangleRegions)assert.ok(Number.isInteger(part)&&part>=0&&part<mesh.regions.length);
for(const id of canonicalMuscles){
  const region=mesh.regions.indexOf(id);assert.ok(region>0);
  const tris=mesh.triangleRegions.map((part,i)=>part===region?i:-1).filter(i=>i>=0);
  assert.ok(tris.length>=100,`${id} has a real surface partition`);
  const xs=tris.flatMap(t=>mesh.indices.slice(t*3,t*3+3).map(i=>mesh.positions[i*3]));
  assert.ok(Math.min(...xs)<0&&Math.max(...xs)>0,`${id} covers both body sides`);
}
for(let i=0;i<mesh.normals.length;i+=3){
  const length=Math.hypot(...mesh.normals.slice(i,i+3));assert.ok(Math.abs(length-1)<0.00001,'Smooth normals are normalized');
}
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
for(const [name,hash] of Object.entries(provenance.sourceSha256))assert.equal(sha(read('assets/'+name)),hash,name);
assert.equal(sha(read('assets/body.mesh.json')),provenance.meshSha256);
for(const name of ['index.html','study.css','study.js','renderer.js','workload.js']){
  const text=read(name).toString();assert.ok(!/https?:\/\//.test(text),`${name} has no network runtime dependency`);
}
const css=read('study.css').toString();
for(const match of css.matchAll(/url\(['"]?([^)'"\s]+)/g))assert.ok(fs.existsSync(path.join(root,match[1])),match[1]);
for(const name of ['SpaceGrotesk-Variable.ttf','SpaceMono-Regular.ttf','SpaceGrotesk-OFL.txt','SpaceMono-OFL.txt'])assert.ok(read('assets/'+name).length>0);
console.log(`PASS: ${fixtures.cases.length} shared calculator goldens; live completion/edit/remove/undo/resume; ${provenance.vertices} vertices / ${provenance.triangles} triangles; eight bilateral partitions; source/mesh hashes; local fonts and offline runtime.`);
