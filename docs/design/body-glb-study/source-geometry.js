// The converter has already applied the scene hierarchy and one uniform
// centering/height normalization. Runtime adds framing metadata only: no
// physique scale, anatomical field, normal rewrite or topology change.
export function sourceMesh(source){
 const {positions,normals}=source;
 if(!positions.length||positions.length%3||normals.length!==positions.length)throw new Error('Invalid source geometry layout');
 const bounds=[[Infinity,Infinity,Infinity],[-Infinity,-Infinity,-Infinity]];let radius=0;
 for(let at=0;at<positions.length;at+=3){
  for(let axis=0;axis<3;axis++){
   const value=positions[at+axis];
   if(!Number.isFinite(value)||!Number.isFinite(normals[at+axis]))throw new Error('Invalid source geometry value');
   bounds[0][axis]=Math.min(bounds[0][axis],value);bounds[1][axis]=Math.max(bounds[1][axis],value);
  }
  if(!(Math.hypot(normals[at],normals[at+1],normals[at+2])>0))throw new Error('Invalid source normal');
  radius=Math.max(radius,Math.hypot(positions[at],positions[at+2]));
 }
 const halfHeight=Math.max(Math.abs(bounds[0][1]),Math.abs(bounds[1][1]));
 if(!(radius>0&&halfHeight>0))throw new Error('Invalid source extent');
 return {...source,bounds,radius,halfHeight};
}
