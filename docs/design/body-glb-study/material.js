// Alpha coverage measured from the bundled Space Mono at 40px in a 24×48
// cell (Pillow/FreeType). These are font metrics, not workout measurements.
export const glyphInk=Object.freeze({'.':.0223,':':.0446,';':.0587,',':.0363,'-':.0316,'_':.0491,'\\':.0961,'/':.0961,'|':.1043,'!':.0808,'+':.0791,'=':.088,'*':.1603,'<':.0956,'>':.0955,'?':.1469,'(':.1505,')':.1499,'[':.1309,']':.1309,'{':.1364,'}':.1369,'1':.1645,'2':.2085,'3':.2037,'4':.1883,'5':.2161,'6':.2257,'7':.1317,'8':.2286,'9':.2262,'0':.2223,'o':.1515,'x':.1227,'v':.1197,'n':.1337,'r':.1308,'s':.1415,'t':.1298,'u':.1325,'z':.1389,'X':.1828,'V':.1743,'A':.2052,'H':.2007,'K':.195,'M':.3072,'N':.2532,'O':.2052});
export const glyphAlphabet=Object.keys(glyphInk).join('');
// Separate optical sizes: the card keeps its native 128×212 slot. Character
// advances are smaller than their cells; density comes from ink, not overlap.
export const samplingPitch=Object.freeze({large:3.2,compact:1.6,aspect:.85});
const roles=['.',':','+','x','*X','AH','N','M'];
export const tonalGlyphs=roles.join('');
const coverage=roles.map(pool=>[...pool].reduce((sum,glyph)=>sum+glyphInk[glyph],0)/pool.length);
const fraction=value=>value-Math.floor(value);
// Three fixed subcell phases distribute rows without displacing their source
// samples. A column keeps its phase at every row, so glyphs cannot overlap.
export const columnPhase=column=>Math.floor(fraction(column*.61803398875)*3)-1;
export function glyphCoverage(alpha,theme,compact){
 const gain=theme==='light'?(compact?1.9:1.15):(compact?1.15:1);
 return gain===1?alpha:1-Math.pow(1-alpha,gain);
}
const clamp=(value,min=0,max=1)=>Math.max(min,Math.min(max,value));
export function materialTone(shade){return clamp((shade/255-.16)/.84);}
export function shapePlaneLight(shade){
 const tone=materialTone(shade);
 // A continuous, monotonic shoulder keeps low planes legible and reserves
 // highlight headroom. This shapes source-normal light, never region ink.
 return 255*(.16+.84*(.08+.84*tone*(1.22-.22*tone)));
}
export function materialAlpha(shade,theme,coverage=1,compact=false){
 const tone=materialTone(shade),floor=theme==='light'?.80:compact?.64:.48;
 // Edge ink retains the source silhouette even when a grazing plane is dark.
 return Math.max(floor+(1-floor)*Math.pow(tone,.65),coverage<1?floor+.10:0);
}
export function materialGlyph(shade,column,row,cell){
 if(cell.coverage===0)return ' ';
 if(cell.coverage<.9&&(cell.gx||cell.gy)){
  const tx=Math.abs(cell.gy),ty=Math.abs(cell.gx);
  return tx>ty*1.8?'-':ty>tx*1.8?'|':cell.gx*cell.gy>0?'/':'\\';
 }
 // Adjacent measured roles mix without a periodic row/column threshold tile.
 // Only near-equal-coverage pairs vary, in quiet 2×2 patches; no full alphabet
 // scrambling. The fixed sampling phases break aligned cap-height scanlines.
 const target=.023+.284*Math.pow(materialTone(shade),1.12);
 let lower=0;while(lower<roles.length-1&&coverage[lower+1]<target)lower++;
 const upper=Math.min(lower+1,roles.length-1),span=coverage[upper]-coverage[lower];
 const mix=span?clamp((target-coverage[lower])/span):0;
 const threshold=fraction(.5+column*.754877666+row*.569840296);
 const pool=roles[threshold<mix?upper:lower];
 const choice=Math.floor(fraction(Math.floor(column/2)*.754877666+Math.floor(row/2)*.569840296)*pool.length);
 return pool[choice];
}

// RGB carries source-normal light, UV region ID and normalized view depth;
// alpha is occupancy. WebGL readPixels is bottom-up. All tone decisions below
// use geometry only, never the region/color channel.
export function sampleSurfaceCell(pixels,width,height,column,row,compact=false,phase=0){
 const points=[],occupied=[];
 for(let y=0;y<3;y++)for(let x=0;x<3;x++){
  const px=column*3+x,py=height-1-(row*3+y+phase),at=(py*width+px)*4;
  const inside=px>=0&&px<width&&py>=0&&py<height;
  points.push({px,py,at});occupied.push(inside&&pixels[at+3]?1:0);
 }
 const count=occupied.reduce((a,b)=>a+b,0);if(!count)return null;
 const anchor=points[occupied[4]?4:occupied.indexOf(1)],depth=pixels[anchor.at+2];
 let light=0,weight=0;
 for(let i=0;i<9;i++)if(occupied[i]&&Math.abs(pixels[points[i].at+2]-depth)<=6){
  light+=pixels[points[i].at];weight++;
 }
 // Opposite samples cancel a plane's slope. Only nearby, mutually visible
 // surface pairs can darken a recess; background/occlusion edges add no rim.
 let cavity=0,pairs=0;
 for(const radius of compact?[3]:[3,6])for(const [dx,dy] of [[1,0],[0,1],[1,1],[1,-1]]){
  const pair=[];
  for(const sign of [-1,1]){
   const x=anchor.px+dx*radius*sign,y=anchor.py+dy*radius*sign;
   if(x<0||x>=width||y<0||y>=height)break;
   const at=(y*width+x)*4;
   if(!pixels[at+3]||Math.abs(pixels[at+2]-depth)>12)break;
   pair.push(pixels[at+2]);
  }
  if(pair.length===2){cavity+=Math.max(0,(pair[0]+pair[1])/2-depth-.75);pairs++;}
 }
 // Broad normal-lit planes lead; local recess contrast remains subordinate
 // and cannot push even the darkest plane down to the punctuation floor.
 const planeLight=shapePlaneLight(light/weight);
 const recess=Math.min(20,pairs?cavity/pairs*4:0,(planeLight-41)*.65);
 const shade=Math.round(clamp(planeLight-recess,41,255));
 return {shade,region:pixels[anchor.at+1],at:anchor.at,coverage:count/9,
  gx:occupied[2]+occupied[5]+occupied[8]-occupied[0]-occupied[3]-occupied[6],
  gy:occupied[6]+occupied[7]+occupied[8]-occupied[0]-occupied[1]-occupied[2]};
}

export const colors={dark:{neutral:[240,240,245],accent:[255,104,53]},light:{neutral:[17,18,23],accent:[168,45,0]}};
export function regionColor(region,muscles,theme){const palette=colors[theme],score=muscles[region]?.score||0;return `rgb(${palette.neutral.map((n,i)=>Math.round(n+(palette.accent[i]-n)*score)).join(",")})`;}
