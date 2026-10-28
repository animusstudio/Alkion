/** Mirrors the pure Dart contract. It accepts synthetic exercise/set inputs. */
export const canonicalMuscles=Object.freeze(['chest','back','shoulders','quads','hamstrings','calves','biceps','triceps']);
export function calculateWorkload(input) {
  const {mode,availability}=input;
  if(availability!=='ready')return {availability,mode,muscles:{},coverage:null};
  const muscles=Object.fromEntries(canonicalMuscles.map(id=>[id,{count:0,score:0}]));
  const coverage={status:'empty',mappedSets:0,unmappedSets:0,unknownKindSets:0,warmupSets:0,pendingSets:0,deletedSets:0};
  for(const exercise of input.exercises)for(const set of exercise.sets){
    if(set.deleted){coverage.deletedSets++;continue;}
    if(mode!=='planned'&&!set.completed){coverage.pendingSets++;continue;}
    if(set.isWarmup===true){coverage.warmupSets++;continue;}
    if(set.isWarmup===null){coverage.unknownKindSets++;continue;}
    if(Object.hasOwn(muscles,exercise.muscleGroup)) {muscles[exercise.muscleGroup].count++;coverage.mappedSets++;}
    else coverage.unmappedSets++;
  }
  const max=Math.max(...Object.values(muscles).map(value=>value.count));
  for(const value of Object.values(muscles))value.score=max?value.count/max:0;
  if(coverage.mappedSets+coverage.unmappedSets+coverage.unknownKindSets>0)
    coverage.status=coverage.unmappedSets+coverage.unknownKindSets===0?'complete':coverage.mappedSets?'partial':'unmapped';
  return {availability,mode,muscles,coverage};
}
