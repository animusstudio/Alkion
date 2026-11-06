// Installed display geometry, independent of any recorded semantic mapping.
// Source frame: height 2, +Y superior, +Z anterior, before pose/fullness.
// These bounded superficial fields are original geometry definitions. They
// never inspect exercise art, anatomical names or workout relationships.
export const surfaceProjectionRevision='alkion-surface-3';
export const surfaceRegions=Object.freeze([null,'chest','back','shoulders','quads','hamstrings','calves','biceps','triceps','glutes','core','forearms','adductors','abductors']);
export const regionProjectionGLSL=`
 float projectRegion(vec3 p,float original){
  float x=abs(p.x);
  // Posterior pelvis: exclude spine/cleft, anterior hip and proximal thighs.
  if(p.y>-.10&&p.y<.17&&x>.025&&x<.205&&p.z<-.035)return 9.0/255.0;
  // Abdominal wall and lateral obliques, below the chest, above the groin.
  if(p.y>.10&&p.y<.405&&x<(.145+.10*(p.y-.10))&&p.z>.005)return 10.0/255.0;
  // Both lower arms, between elbow and wrist; hands and upper arms excluded.
  if(p.y>.035&&p.y<.305&&x>.335&&x<.515)return 11.0/255.0;
  // The hip fields below claim only surface the source masks leave unpainted,
  // so the painted quads and hamstrings keep the thigh at every angle.
  if(original>.5/255.0)return original;
  // Lateral hip, iliac crest to greater trochanter, beside the pelvis.
  if(p.y>-.07&&p.y<.17&&x>(.158-.20*p.y)&&x<.25&&p.z>-.06&&p.z<.05)return 13.0/255.0;
  // Medial proximal thigh, groin toward mid-thigh, front and back.
  if(p.y>-.32&&p.y<-.02&&x>.03&&x<(.075+.14*(p.y+.32))&&p.z>-.08&&p.z<.10)return 12.0/255.0;
  return original;
 }`;
