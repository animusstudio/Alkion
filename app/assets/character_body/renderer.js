import {glyphAlphabet,tonalGlyphs,glyphRoles,glyphRoleMix,glyphThreshold,glyphChoice,samplingPitch,columnPhase,glyphCoverage,sampleSurfaceCell,materialGlyph,materialAlpha,regionColor,colors} from './material.js';
import {bodyFit,fullerMesh} from './geometry.js';
import {posedMesh} from './pose-geometry.js';
import {regions,maxPitch} from './protocol.js';
import {surfaceRegions,regionProjectionGLSL,surfaceProjectionRevision} from './regions.js';

// The caller owns a two-style cache; failed or aborted loads are never retained.
export async function loadMesh(style,signal,timings={}){
 if(style!=='male'&&style!=='female')throw new Error('Invalid body style');
 const root=`models/${style}/`,start=performance.now();
 const fetchPart=async name=>{const response=await fetch(root+name,{signal});if(!response.ok)throw new Error(response.status===404?'art_unavailable':'art_error');return response;};
 const mask=new Image();mask.src=root+'regions.png';
 const maskReady=mask.decode().then(()=>{timings.maskMs=performance.now()-start;return mask;});
 // All immutable inputs are independent. Hash/layout validation still precedes use.
 const [manifest,bytes,masks]=await Promise.all([
  fetchPart('body.mesh.json').then(response=>response.json()).then(value=>{timings.manifestMs=performance.now()-start;return value;}),
  fetchPart('body.mesh.bin').then(response=>response.arrayBuffer()).then(value=>{timings.binaryMs=performance.now()-start;return value;}),maskReady,
 ]);
 if(signal?.aborted)throw new Error('aborted');
 if(manifest.version!==1||manifest.binary!=='body.mesh.bin')throw new Error('Unsupported body mesh');
 const hashStart=performance.now();
 const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),n=>n.toString(16).padStart(2,'0')).join('');
 timings.hashMs=performance.now()-hashStart;
 if(signal?.aborted)throw new Error('aborted');
 if(hash!==manifest.sha256)throw new Error('Body mesh integrity mismatch');
 const data={manifest,masks},types={'<f4':Float32Array,'<u4':Uint32Array,'|u1':Uint8Array};
 for(const [name,a] of Object.entries(manifest.attributes)){
  const Type=types[a.type];if(!Type||!Number.isSafeInteger(a.count)||a.count<=0||a.byteOffset<0||a.byteOffset%Type.BYTES_PER_ELEMENT||a.byteOffset+a.count*Type.BYTES_PER_ELEMENT>bytes.byteLength)throw new Error('Invalid body mesh attribute');
  data[name]=new Type(bytes,a.byteOffset,a.count);
 }
 if(data.positions.length!==manifest.vertices*3||data.normals.length!==data.positions.length||data.uv.length!==manifest.vertices*2||data.indices.length!==manifest.triangles*3)throw new Error('Body mesh layout mismatch');
 const prepareStart=performance.now(),prepared=style==='female'?posedMesh(data):fullerMesh(data);
 timings.prepareMs=performance.now()-prepareStart;return {...prepared,regionPositions:data.positions};
}

/** A null/unknown atlas entry can never be a selection, including no selection. */
export function atlasRegionColor(region,muscles,theme,selected=null){
 return selected!==null&&regions.includes(selected)&&region===selected?`rgb(${colors[theme].accent.join(',')})`:regionColor(region,muscles,theme);
}

// Per-mesh height bins with their widest radial (x,z) distance: one O(n) pass,
// then tilted bounds over bins only. Bin edges keep every bound conservative.
const orbitBins=new WeakMap(),binCount=512;
function heightBins(mesh,centerY){
 let bins=orbitBins.get(mesh);if(bins)return bins;
 const p=mesh.positions,low=mesh.bounds[0][1]-centerY,span=Math.max(1e-9,mesh.bounds[1][1]-mesh.bounds[0][1]),radial=new Float64Array(binCount).fill(-1);
 for(let at=0;at<p.length;at+=3){const bin=Math.min(binCount-1,Math.floor((p[at+1]-centerY-low)/span*binCount));radial[bin]=Math.max(radial[bin],Math.hypot(p[at],p[at+2]));}
 bins=[];for(let bin=0;bin<binCount;bin++)if(radial[bin]>=0)bins.push([low+bin*span/binCount,low+(bin+1)*span/binCount,radial[bin]]);
 orbitBins.set(mesh,bins);return bins;
}

/**
 * Camera elevation orbits the body's vertical centre after yaw. Pitch 0 is the
 * accepted frame exactly: depth range = radial extent, extent = half height.
 * A tilt bounds every vertex at any yaw, |y'| = |c + (y-c)cos - z sin| and
 * |z'| = |(y-c)sin + z cos| with |z| at most the vertex's radial distance, so
 * nothing is clipped; neither range ever narrows below the level frame's.
 */
export function orbitFrame(mesh,pitch=0){
 const p=Math.max(-maxPitch,Math.min(maxPitch,Number.isFinite(pitch)?pitch:0)),cos=Math.cos(p),sin=Math.sin(p),s=Math.abs(sin);
 const centerY=mesh.bounds?(mesh.bounds[0][1]+mesh.bounds[1][1])/2:0;
 if(p===0)return {cos,sin,centerY,depthRange:mesh.radius,extent:mesh.halfHeight};
 let extent=0,depth=0;
 if(mesh.positions&&mesh.bounds){
  for(const [a,b,r] of heightBins(mesh,centerY)){
   extent=Math.max(extent,Math.abs(centerY+a*cos)+r*s,Math.abs(centerY+b*cos)+r*s);
   depth=Math.max(depth,Math.max(Math.abs(a),Math.abs(b))*s+r*cos);
  }
 }else{
  const reach=mesh.bounds?Math.max(mesh.bounds[1][1]-centerY,centerY-mesh.bounds[0][1]):mesh.halfHeight;
  extent=Math.abs(centerY)+reach*cos+mesh.radius*s;depth=mesh.radius*cos+reach*s;
 }
 return {cos,sin,centerY,depthRange:Math.max(mesh.radius,depth),extent:Math.max(mesh.halfHeight,extent)};
}

const glyphIndices=Object.fromEntries([...glyphAlphabet].map((glyph,index)=>[glyph,index]));
const diagnosticColors=[[118,124,138],[255,105,70],[100,165,255],[240,190,70],[140,210,100],[200,140,240],[70,205,200],[245,130,190],[170,180,250],[255,145,70],[110,225,145],[240,100,170],[255,235,40],[40,235,255]];

/** Sample only the frontmost retained raster pixel; no radius or neighbour search. */
export function pickSurfaceRegion(pixels,width,height,manifestRegions,x,y){
 if(!pixels||!Number.isInteger(width)||!Number.isInteger(height)||width<=0||height<=0||pixels.length!==width*height*4||!Number.isFinite(x)||!Number.isFinite(y)||x<0||y<0||x>=1||y>=1)return null;
 const at=((height-1-Math.floor(y*height))*width+Math.floor(x*width))*4;
 const region=manifestRegions[pixels[at+1]];
 return pixels[at+3]&&regions.includes(region)?region:null;
}

// GPU compose (WebGL2). The cell pass mirrors sampleSurfaceCell and
// materialGlyph on the retained surface bytes with integer arithmetic; every
// float-sensitive decision (role mix, cell threshold and choice, column phase,
// alpha) comes from CPU tables built with the same material.js functions. The
// glyph pass draws every cell in one instanced call, in the CPU path's row-major
// order, sampling the same atlas with the same placement and source-over blend.
const glyphIndex=glyph=>glyphAlphabet.indexOf(glyph);
const roleGlyphs=glyphRoles.flatMap(pool=>[glyphIndex(pool[0]),glyphIndex(pool[pool.length-1])]);
const roleLengths=glyphRoles.map(pool=>pool.length);
export const cellPassGLSL=`#version 300 es
precision highp float;precision highp int;precision highp sampler2D;
uniform sampler2D surface;uniform sampler2D cellInfo;uniform sampler2D shades;
uniform ivec2 surfaceSize;uniform bool compact;
out vec4 result;
const int DX[4]=int[4](1,0,1,1);const int DY[4]=int[4](0,1,1,-1);
const int ROLE_GLYPH[${roleGlyphs.length}]=int[${roleGlyphs.length}](${roleGlyphs.join(',')});
const int ROLE_LENGTH[${roleLengths.length}]=int[${roleLengths.length}](${roleLengths.join(',')});
ivec4 at(int x,int y){return ivec4(round(texelFetch(surface,ivec2(x,y),0)*255.0));}
bool inside(int x,int y){return x>=0&&x<surfaceSize.x&&y>=0&&y<surfaceSize.y;}
float planeLight(float shade){
 float tone=clamp((shade/255.0-.16)/.84,0.0,1.0);
 return 255.0*(.16+.84*(.08+.84*tone*(1.22-.22*tone)));
}
void main(){
 ivec2 cell=ivec2(gl_FragCoord.xy);vec4 info=texelFetch(cellInfo,cell,0);
 int phase=int(info.z),left=cell.x*3,top=surfaceSize.y-1-(cell.y*3+phase);
 int occupied=0,count=0,first=0;
 for(int i=0;i<9;i++){int x=left+i%3,y=top-i/3;if(inside(x,y)&&at(x,y).a!=0){occupied|=1<<i;if(count==0)first=i;count++;}}
 if(count==0){result=vec4(0.0);return;}
 int anchor=(occupied&16)!=0?4:first,ax=left+anchor%3,ay=top-anchor/3;ivec4 a=at(ax,ay);int depth=a.b;
 int light=0,weight=0;
 for(int i=0;i<9;i++)if((occupied&(1<<i))!=0){ivec4 p=at(left+i%3,top-i/3);if(abs(p.b-depth)<=6){light+=p.r;weight++;}}
 float cavity=0.0;int pairs=0;
 for(int radius=3;radius<=(compact?3:6);radius+=3)for(int d=0;d<4;d++){
  int dx=DX[d]*radius,dy=DY[d]*radius,x1=ax-dx,y1=ay-dy;
  if(!inside(x1,y1))continue;ivec4 p1=at(x1,y1);if(p1.a==0||abs(p1.b-depth)>12)continue;
  int x2=ax+dx,y2=ay+dy;if(!inside(x2,y2))continue;ivec4 p2=at(x2,y2);if(p2.a==0||abs(p2.b-depth)>12)continue;
  cavity+=max(0.0,float(p1.b+p2.b)/2.0-float(depth)-.75);pairs++;
 }
 float plane=planeLight(float(light)/float(weight));
 float recess=min(20.0,min(pairs>0?cavity/float(pairs)*4.0:0.0,(plane-41.0)*.65));
 int shade=int(floor(clamp(plane-recess,41.0,255.0)+.5));
 int gx=((occupied>>2)&1)+((occupied>>5)&1)+((occupied>>8)&1)-(occupied&1)-((occupied>>3)&1)-((occupied>>6)&1);
 int gy=((occupied>>6)&1)+((occupied>>7)&1)+((occupied>>8)&1)-(occupied&1)-((occupied>>1)&1)-((occupied>>2)&1);
 int glyph;
 if(count<9&&(gx!=0||gy!=0)){
  int tx=abs(gy),ty=abs(gx);
  glyph=float(tx)>float(ty)*1.8?${glyphIndex('-')}:float(ty)>float(tx)*1.8?${glyphIndex('|')}:gx*gy>0?${glyphIndex('/')}:${glyphIndex('\\')};
 }else{
  vec4 role=texelFetch(shades,ivec2(shade,0),0);int pool=info.x<role.x?int(role.z):int(role.y);
  glyph=ROLE_GLYPH[pool*2+(ROLE_LENGTH[pool]>1?int(info.y):0)];
 }
 result=vec4(float(glyph),float(a.g),float(shade),float(count))/255.0;
}`;
export const glyphPassGLSL=[`#version 300 es
precision highp float;precision highp int;precision highp sampler2D;
uniform sampler2D cells;uniform sampler2D cellInfo;uniform sampler2D shades;
uniform int cols;uniform vec2 canvasSize;uniform vec2 cellSize;uniform vec2 tileSize;uniform vec2 atlasSize;
out vec2 atlasUV;out float alpha;
void main(){
 int col=gl_InstanceID%cols,row=gl_InstanceID/cols;
 ivec4 c=ivec4(round(texelFetch(cells,ivec2(col,row),0)*255.0));
 if(c.a==0){gl_Position=vec4(2.0,2.0,2.0,1.0);atlasUV=vec2(0.0);alpha=0.0;return;}
 vec2 corner=vec2(float(gl_VertexID&1),float(gl_VertexID>>1));
 float phase=texelFetch(cellInfo,ivec2(col,row),0).z;
 vec2 origin=vec2(float(col)*cellSize.x+(cellSize.x-tileSize.x)/2.0,(float(row)+phase/3.0)*cellSize.y+(cellSize.y-tileSize.y)/2.0);
 vec2 p=origin+corner*tileSize;
 gl_Position=vec4(p.x/canvasSize.x*2.0-1.0,1.0-p.y/canvasSize.y*2.0,0.0,1.0);
 atlasUV=(vec2(float(c.r),float(c.g))*tileSize+corner*tileSize)/atlasSize;
 vec4 a=texelFetch(shades,ivec2(c.b,1),0);alpha=c.a<9?a.y:a.x;
}`,`#version 300 es
precision highp float;uniform sampler2D atlas;in vec2 atlasUV;in float alpha;out vec4 color;
void main(){color=texture(atlas,atlasUV)*alpha;}`];
const fullScreenGLSL=`#version 300 es
void main(){gl_Position=vec4(float((gl_VertexID&1)*4-1),float((gl_VertexID>>1)*4-1),0.0,1.0);}`;

/** A real indexed depth-buffered surface sampled into character cells. */
export class VolumeRenderer{
 constructor(canvas,mesh,compact=false,{diagnostics=false,compose='auto'}={}){
  this.diagnostics=diagnostics;
  this.canvas=canvas;this.mesh=mesh;this.compact=compact;this.sample={};this.drawCount=0;this.glyphCount=0;
  this.ctx=canvas.getContext('2d');if(!this.ctx)throw new Error('Canvas unavailable');
  this.surface=document.createElement('canvas');
  // WebGL2 composes glyphs on the GPU; WebGL1 keeps the CPU reference path.
  const gl2=compose!=='cpu'?this.surface.getContext('webgl2',{alpha:true,antialias:false,depth:false,premultipliedAlpha:true,preserveDrawingBuffer:false}):null;
  this.gpu=!!gl2;
  const gl=this.gl=gl2||this.surface.getContext('webgl',{alpha:true,antialias:false,preserveDrawingBuffer:true});
  if(!gl||!(this.gpu||gl.getExtension('OES_element_index_uint')))throw new Error('Indexed graphics unavailable');
  if(compose==='gpu'&&!this.gpu)throw new Error('GPU compose unavailable');
  if(this.gpu){this.geometryVAO=gl.createVertexArray();gl.bindVertexArray(this.geometryVAO);}
  const compile=(type,source)=>{const shader=gl.createShader(type);gl.shaderSource(shader,source);gl.compileShader(shader);if(!gl.getShaderParameter(shader,gl.COMPILE_STATUS))throw new Error(gl.getShaderInfoLog(shader));return shader;};
  const vs=compile(gl.VERTEX_SHADER,`
   attribute vec3 position;attribute vec3 normal;attribute vec2 uv;attribute vec3 regionPosition;
   uniform float yaw;uniform vec2 pitch;uniform float centerY;uniform float aspect;uniform float fit;uniform float depthRange;uniform vec2 pan;
   varying vec3 viewNormal;varying vec2 sourceUV;varying float sourceDepth;varying vec3 sourcePosition;
   void main(){float c=cos(yaw),s=sin(yaw),pc=pitch.x,ps=pitch.y;vec3 q=vec3(c*position.x+s*position.z,position.y-centerY,-s*position.x+c*position.z);
    // Positive pitch raises the camera: the top leans toward the viewer.
    // At pitch 0 (pc=1, ps=0) every term reduces exactly to the accepted frame.
    vec3 p=vec3(q.x,position.y+(pc-1.0)*q.y-ps*q.z,ps*q.y+pc*q.z);
    vec3 yn=vec3(c*normal.x+s*normal.z,normal.y,-s*normal.x+c*normal.z);
    sourceDepth=.5+p.z/(2.0*depthRange);viewNormal=vec3(yn.x,pc*yn.y-ps*yn.z,ps*yn.y+pc*yn.z);sourceUV=uv;sourcePosition=regionPosition;
    gl_Position=vec4(p.x*fit/aspect+pan.x,p.y*fit+pan.y,-p.z/depthRange,1.0);}`);
  const fs=compile(gl.FRAGMENT_SHADER,`
   precision mediump float;uniform sampler2D sourceMasks;
   varying vec3 viewNormal;varying vec2 sourceUV;varying float sourceDepth;varying vec3 sourcePosition;
   ${regionProjectionGLSL}
   void main(){vec3 vn=normalize(viewNormal);
    vec4 mask=texture2D(sourceMasks,sourceUV);
    float diffuse=max(0.0,dot(vn,normalize(vec3(-.65,.80,.85))));
    float fill=max(0.0,dot(vn,normalize(vec3(.65,.10,1.0))));
    // Keep one dominant upper-side key; the broader frontal fill carries
    // shadow-facing limbs without adding a rim or a specular lobe.
    float shade=.16+.72*diffuse+.12*fill;
    // Posed female-source surface and inverse-Jacobian transported normals.
    // The atlas contributes identity only;
    // its original colors and printed muscle abbreviations never enter tone.
    gl_FragColor=vec4(shade,projectRegion(sourcePosition,mask.r),sourceDepth,1.0);}`);
  const program=this.program=gl.createProgram();gl.attachShader(program,vs);gl.attachShader(program,fs);gl.linkProgram(program);
  if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw new Error(gl.getProgramInfoLog(program));
  gl.deleteShader(vs);gl.deleteShader(fs);gl.useProgram(program);this.buffers=[];
  for(const [name,size,data] of [['position',3,mesh.positions],['normal',3,mesh.normals],['uv',2,mesh.uv],['regionPosition',3,mesh.regionPositions]]){
   const buffer=gl.createBuffer();this.buffers.push(buffer);gl.bindBuffer(gl.ARRAY_BUFFER,buffer);gl.bufferData(gl.ARRAY_BUFFER,data,gl.STATIC_DRAW);
   const location=gl.getAttribLocation(program,name);gl.enableVertexAttribArray(location);gl.vertexAttribPointer(location,size,gl.FLOAT,false,0,0);
  }
  const index=gl.createBuffer();this.buffers.push(index);gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,index);gl.bufferData(gl.ELEMENT_ARRAY_BUFFER,mesh.indices,gl.STATIC_DRAW);
  this.texture=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,this.texture);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
  gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,mesh.masks);gl.uniform1i(gl.getUniformLocation(program,'sourceMasks'),0);
  this.fitLocation=gl.getUniformLocation(program,'fit');this.panLocation=gl.getUniformLocation(program,'pan');
  this.depthLocation=gl.getUniformLocation(program,'depthRange');this.pitchLocation=gl.getUniformLocation(program,'pitch');this.centerLocation=gl.getUniformLocation(program,'centerY');
  this.yawLocation=gl.getUniformLocation(program,'yaw');this.aspectLocation=gl.getUniformLocation(program,'aspect');
  gl.enable(gl.DEPTH_TEST);gl.depthFunc(gl.LESS);gl.disable(gl.BLEND);gl.disable(gl.DITHER);
  this.atlas=document.createElement('canvas');this.lost=false;
  if(this.gpu)this.createComposer(compile);
  this.surface.addEventListener('webglcontextlost',event=>{event.preventDefault();if(this.disposed)return;this.lost=true;canvas.dispatchEvent(new Event('renderfailure'));});
 }
 resize(){
  const width=this.canvas.clientWidth,height=this.canvas.clientHeight;if(!width||!height)return false;
  const dpr=Math.min(devicePixelRatio||1,2),w=Math.round(width*dpr),h=Math.round(height*dpr);
  if(w===this.canvas.width&&h===this.canvas.height&&this.pixels)return true;
  this.canvas.width=w;this.canvas.height=h;const pitch=this.compact?samplingPitch.compact:samplingPitch.large;
  this.cols=Math.max(1,Math.round(width/pitch));this.rows=Math.max(1,Math.round(height/(pitch/samplingPitch.aspect)));
  // The retained geometry surface is three samples per cell side on both paths.
  this.gw=this.cols*3;this.gh=this.rows*3;
  if(this.gpu){this.surface.width=w;this.surface.height=h;this.resizeComposer();}
  else{this.surface.width=this.gw;this.surface.height=this.gh;this.gl.viewport(0,0,this.gw,this.gh);}
  this.pixels=new Uint8Array(this.gw*this.gh*4);this.atlasKey='';return true;
 }
 buildAtlas(muscles,theme,selected=null){
  const key=JSON.stringify([muscles,theme,selected,colors[theme],this.cols,this.rows,this.canvas.width]);if(key===this.atlasKey)return;this.atlasKey=key;
  this.cellW=this.canvas.width/this.cols;this.cellH=this.canvas.height/this.rows;this.tileW=Math.ceil(this.cellW+3);this.tileH=Math.ceil(this.cellH+3);
  this.atlas.width=this.tileW*glyphAlphabet.length;this.atlas.height=this.tileH*surfaceRegions.length;
  // Measure visible ink rather than the em/advance box. Space Mono capitals
  // occupy about 70% of an em; em fitting left empty bands between every row.
  const ctx=this.atlas.getContext('2d');ctx.font='400 100px "Space Mono"';
  ctx.textAlign='left';ctx.textBaseline='alphabetic';
  const metrics=[...glyphAlphabet].map(glyph=>{
   const m=ctx.measureText(glyph);
   return {left:m.actualBoundingBoxLeft/100,right:m.actualBoundingBoxRight/100,
    ascent:m.actualBoundingBoxAscent/100,descent:m.actualBoundingBoxDescent/100};
  });
  const faces=[...tonalGlyphs].map(glyph=>metrics[glyphAlphabet.indexOf(glyph)]);
  // A little more space around each glyph: .89 instead of .94 reduces its
  // nominal ink area by 10.4%, without dropping cells or dimming their ink.
  const inkFit=.89;
  const fontSize=Math.min(this.cellW*inkFit/Math.max(...faces.map(m=>m.left+m.right)),
   this.cellH*inkFit/Math.max(...faces.map(m=>m.ascent+m.descent)));
  // Resolve small font coverage from a supersampled atlas, then calibrate ink
  // opacity. Transparent pixels remain transparent; no stroke/underlay is added.
  const raster=document.createElement('canvas'),scale=4;
  raster.width=this.atlas.width*scale;raster.height=this.atlas.height*scale;
  const ink=raster.getContext('2d');ink.scale(scale,scale);ink.textAlign='left';ink.textBaseline='alphabetic';
  surfaceRegions.forEach((region,i)=>{
   ink.fillStyle=atlasRegionColor(region,muscles,theme,selected);
   for(let g=0;g<glyphAlphabet.length;g++){
    const m=metrics[g],size=Math.min(fontSize,this.cellW*inkFit/(m.left+m.right),this.cellH*inkFit/(m.ascent+m.descent));
    ink.font=`400 ${size}px "Space Mono"`;
    ink.fillText(glyphAlphabet[g],g*this.tileW+this.tileW/2-(m.right-m.left)*size/2,
     i*this.tileH+this.tileH/2+(m.ascent-m.descent)*size/2);
   }
  });
  ctx.drawImage(raster,0,0,this.atlas.width,this.atlas.height);
  const coverage=ctx.getImageData(0,0,this.atlas.width,this.atlas.height);
  for(let at=3;at<coverage.data.length;at+=4)coverage.data[at]=Math.round(255*glyphCoverage(coverage.data[at]/255,theme,this.compact));
  ctx.putImageData(coverage,0,0);this.atlasDirty=true;
 }
 draw(yaw,muscles,theme,mode='characters',selected=null,view={zoom:1,x:0,y:0,pitch:0}){
  if(this.lost)throw new Error('Graphics context lost');if(!this.resize())return;
  this.buildAtlas(muscles,theme,selected);const gl=this.gl;gl.useProgram(this.program);gl.uniform1f(this.yawLocation,yaw);
  const orbit=orbitFrame(this.mesh,view.pitch??0);gl.uniform2f(this.pitchLocation,orbit.cos,orbit.sin);gl.uniform1f(this.centerLocation,orbit.centerY);gl.uniform1f(this.depthLocation,orbit.depthRange);const aspect=this.canvas.width/this.canvas.height;gl.uniform1f(this.aspectLocation,aspect);gl.uniform1f(this.fitLocation,(orbit.extent===this.mesh.halfHeight?bodyFit(this.mesh,aspect):Math.min(.96/orbit.extent,.96*aspect/this.mesh.radius))*view.zoom);gl.uniform2f(this.panLocation,view.x*2,-view.y*2);
  const t0=performance.now();
  if(this.gpu){gl.bindVertexArray(this.geometryVAO);gl.bindFramebuffer(gl.FRAMEBUFFER,this.geometryFBO);gl.viewport(0,0,this.gw,this.gh);gl.enable(gl.DEPTH_TEST);gl.disable(gl.BLEND);gl.activeTexture(gl.TEXTURE0);gl.bindTexture(gl.TEXTURE_2D,this.texture);}
  gl.clearColor(0,0,0,0);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);gl.drawElements(gl.TRIANGLES,this.mesh.indices.length,gl.UNSIGNED_INT,0);
  const t1=performance.now();gl.readPixels(0,0,this.gw,this.gh,gl.RGBA,gl.UNSIGNED_BYTE,this.pixels);
  const t2=performance.now();this.stageGl=t1-t0;this.stageRead=t2-t1;this.stageCompose=0;
  this.pickWidth=this.canvas.clientWidth;this.pickHeight=this.canvas.clientHeight;
  if(mode!=='characters'){this.drawDiagnostic(mode,theme);return;}
  if(this.gpu){this.composeGPU(theme);this.stageCompose=performance.now()-t2;this.drawCount++;this.canvas.dataset.yaw=String(yaw);this.canvas.dataset.pitch=String(view.pitch??0);return;}
  const ctx=this.ctx,pixels=this.pixels,stride=this.gw;ctx.clearRect(0,0,this.canvas.width,this.canvas.height);
  let count=0,signature=2166136261;const histogram={};
  for(let row=0;row<this.rows;row++)for(let col=0;col<this.cols;col++){
   const phase=columnPhase(col);
   const cell=sampleSurfaceCell(pixels,stride,this.gh,col,row,this.compact,phase,this.sample);if(!cell)continue;
   const glyph=materialGlyph(cell.shade,col,row,cell);if(glyph===' ')continue;
   const g=glyphIndices[glyph];
   ctx.globalAlpha=materialAlpha(cell.shade,theme,cell.coverage,this.compact);
   ctx.drawImage(this.atlas,g*this.tileW,cell.region*this.tileH,this.tileW,this.tileH,col*this.cellW+(this.cellW-this.tileW)/2,(row+phase/3)*this.cellH+(this.cellH-this.tileH)/2,this.tileW,this.tileH);
   count++;histogram[glyph]=(histogram[glyph]||0)+1;
   signature=Math.imul(signature^cell.at^cell.shade^glyph.charCodeAt(0)^phase,16777619)>>>0;
  }
  ctx.globalAlpha=1;this.stageCompose=performance.now()-t2;this.drawCount++;this.glyphCount=count;this.canvas.dataset.glyphCount=String(count);this.canvas.dataset.materialSignature=String(signature);this.canvas.dataset.glyphHistogram=JSON.stringify(histogram);this.canvas.dataset.yaw=String(yaw);this.canvas.dataset.pitch=String(view.pitch??0);this.canvas.dataset.surfaceProjection=surfaceProjectionRevision;if(this.diagnostics){const regionPixels={};for(let at=0;at<this.pixels.length;at+=4)if(this.pixels[at+3]){const id=surfaceRegions[this.pixels[at+1]];if(id)regionPixels[id]=(regionPixels[id]||0)+1;}this.canvas.dataset.regionPixels=JSON.stringify(regionPixels);}
 }
 // Normalized native coordinates address the retained, depth-tested surface,
 // not a nearby glyph/anchor. WebGL readback rows run bottom to top.
 pick(x,y){
  if(this.lost||this.pickWidth!==this.canvas.clientWidth||this.pickHeight!==this.canvas.clientHeight)return null;
  return pickSurfaceRegion(this.pixels,this.gw,this.gh,surfaceRegions,x,y);
 }
 drawDiagnostic(mode,theme){
  const width=this.gw,height=this.gh,pixels=new Uint8ClampedArray(width*height*4);
  for(let y=0;y<height;y++)for(let x=0;x<width;x++){
   const source=((height-y-1)*width+x)*4,target=(y*width+x)*4;if(!this.pixels[source+3])continue;
   const tone=this.pixels[source]/255,region=this.pixels[source+1];
   const color=mode==='regions'?diagnosticColors[region]:(theme==='light'?[75,80,88]:[240,240,245]);
   for(let c=0;c<3;c++)pixels[target+c]=color[c]*(.38+.62*tone);
   pixels[target+3]=255;
  }
  this.diagnostic??=document.createElement('canvas');this.diagnostic.width=width;this.diagnostic.height=height;
  this.diagnostic.getContext('2d').putImageData(new ImageData(pixels,width,height),0,0);
  this.ctx.clearRect(0,0,this.canvas.width,this.canvas.height);this.ctx.drawImage(this.diagnostic,0,0,this.canvas.width,this.canvas.height);
  this.drawCount++;this.glyphCount=0;this.canvas.dataset.glyphCount='0';this.canvas.dataset.materialSignature='diagnostic';this.canvas.dataset.glyphHistogram='{}';
 }
 createComposer(compile){
  const gl=this.gl,link=(vs,fs)=>{const program=gl.createProgram(),v=compile(gl.VERTEX_SHADER,vs),f=compile(gl.FRAGMENT_SHADER,fs);gl.attachShader(program,v);gl.attachShader(program,f);gl.linkProgram(program);
   if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw new Error(gl.getProgramInfoLog(program));gl.deleteShader(v);gl.deleteShader(f);return program;};
  this.cellProgram=link(fullScreenGLSL,cellPassGLSL);this.glyphProgram=link(...glyphPassGLSL);this.emptyVAO=gl.createVertexArray();
  const uniforms=(program,names)=>Object.fromEntries(names.map(name=>[name,gl.getUniformLocation(program,name)]));
  this.cellUniforms=uniforms(this.cellProgram,['surface','cellInfo','shades','surfaceSize','compact']);
  this.glyphUniforms=uniforms(this.glyphProgram,['cells','cellInfo','shades','cols','canvasSize','cellSize','tileSize','atlasSize','atlas']);
  const texture=(filter=gl.NEAREST)=>{const t=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,t);for(const [k,v] of [[gl.TEXTURE_MIN_FILTER,filter],[gl.TEXTURE_MAG_FILTER,filter],[gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE],[gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE]])gl.texParameteri(gl.TEXTURE_2D,k,v);return t;};
  this.geometryTexture=texture();this.cellTexture=texture();this.cellInfoTexture=texture();this.shadeTexture=texture();this.atlasTexture=texture(gl.LINEAR);
  this.depthBuffer=gl.createRenderbuffer();this.geometryFBO=gl.createFramebuffer();this.cellFBO=gl.createFramebuffer();this.shadeKey='';
 }
 resizeComposer(){
  const gl=this.gl,cols=this.cols,rows=this.rows;
  gl.bindTexture(gl.TEXTURE_2D,this.geometryTexture);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA8,this.gw,this.gh,0,gl.RGBA,gl.UNSIGNED_BYTE,null);
  gl.bindRenderbuffer(gl.RENDERBUFFER,this.depthBuffer);gl.renderbufferStorage(gl.RENDERBUFFER,gl.DEPTH_COMPONENT24,this.gw,this.gh);
  gl.bindFramebuffer(gl.FRAMEBUFFER,this.geometryFBO);gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,this.geometryTexture,0);gl.framebufferRenderbuffer(gl.FRAMEBUFFER,gl.DEPTH_ATTACHMENT,gl.RENDERBUFFER,this.depthBuffer);
  gl.bindTexture(gl.TEXTURE_2D,this.cellTexture);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA8,cols,rows,0,gl.RGBA,gl.UNSIGNED_BYTE,null);
  gl.bindFramebuffer(gl.FRAMEBUFFER,this.cellFBO);gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,this.cellTexture,0);
  if(gl.checkFramebufferStatus(gl.FRAMEBUFFER)!==gl.FRAMEBUFFER_COMPLETE)throw new Error('Cell surface unavailable');
  gl.bindFramebuffer(gl.FRAMEBUFFER,this.geometryFBO);if(gl.checkFramebufferStatus(gl.FRAMEBUFFER)!==gl.FRAMEBUFFER_COMPLETE)throw new Error('Geometry surface unavailable');
  // Per-cell constants, from the CPU path's own functions: threshold, the
  // 2×2 pool choice and the column phase.
  const info=new Float32Array(cols*rows*4);
  for(let row=0;row<rows;row++)for(let col=0;col<cols;col++){const at=(row*cols+col)*4;info[at]=glyphThreshold(col,row);info[at+1]=glyphChoice(col,row,2);info[at+2]=columnPhase(col);}
  gl.bindTexture(gl.TEXTURE_2D,this.cellInfoTexture);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA32F,cols,rows,0,gl.RGBA,gl.FLOAT,info);
  gl.bindFramebuffer(gl.FRAMEBUFFER,null);this.shadeKey='';
 }
 composeGPU(theme){
  const gl=this.gl,key=`${theme}/${this.compact}`;
  if(this.shadeKey!==key){
   // Row 0: role mix by shade. Row 1: alpha by shade, full and partial cells.
   const table=new Float32Array(256*2*4);
   for(let shade=0;shade<256;shade++){const {lower,upper,mix}=glyphRoleMix(shade),at=shade*4,alpha=(256+shade)*4;
    table[at]=mix;table[at+1]=lower;table[at+2]=upper;table[alpha]=materialAlpha(shade,theme,1,this.compact);table[alpha+1]=materialAlpha(shade,theme,8/9,this.compact);}
   gl.bindTexture(gl.TEXTURE_2D,this.shadeTexture);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA32F,256,2,0,gl.RGBA,gl.FLOAT,table);this.shadeKey=key;
  }
  if(this.atlasDirty){gl.bindTexture(gl.TEXTURE_2D,this.atlasTexture);gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL,true);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,this.atlas);gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL,false);this.atlasDirty=false;}
  const bind=(unit,texture,location)=>{gl.activeTexture(gl.TEXTURE0+unit);gl.bindTexture(gl.TEXTURE_2D,texture);gl.uniform1i(location,unit);};
  gl.bindVertexArray(this.emptyVAO);gl.disable(gl.DEPTH_TEST);
  // One sampler evaluation per cell into a cols×rows byte surface.
  gl.bindFramebuffer(gl.FRAMEBUFFER,this.cellFBO);gl.viewport(0,0,this.cols,this.rows);gl.disable(gl.BLEND);
  gl.useProgram(this.cellProgram);const cu=this.cellUniforms;
  bind(1,this.geometryTexture,cu.surface);bind(2,this.cellInfoTexture,cu.cellInfo);bind(3,this.shadeTexture,cu.shades);
  gl.uniform2i(cu.surfaceSize,this.gw,this.gh);gl.uniform1i(cu.compact,this.compact?1:0);gl.drawArrays(gl.TRIANGLES,0,3);
  // Every glyph in one instanced draw, premultiplied source-over as Canvas.
  gl.bindFramebuffer(gl.FRAMEBUFFER,null);gl.viewport(0,0,this.surface.width,this.surface.height);gl.clearColor(0,0,0,0);gl.clear(gl.COLOR_BUFFER_BIT);
  gl.enable(gl.BLEND);gl.blendFunc(gl.ONE,gl.ONE_MINUS_SRC_ALPHA);gl.useProgram(this.glyphProgram);const gu=this.glyphUniforms;
  bind(1,this.cellTexture,gu.cells);bind(2,this.cellInfoTexture,gu.cellInfo);bind(3,this.shadeTexture,gu.shades);bind(4,this.atlasTexture,gu.atlas);
  gl.uniform1i(gu.cols,this.cols);gl.uniform2f(gu.canvasSize,this.canvas.width,this.canvas.height);gl.uniform2f(gu.cellSize,this.cellW,this.cellH);gl.uniform2f(gu.tileSize,this.tileW,this.tileH);gl.uniform2f(gu.atlasSize,this.atlas.width,this.atlas.height);
  gl.drawArraysInstanced(gl.TRIANGLE_STRIP,0,4,this.cols*this.rows);gl.disable(gl.BLEND);gl.useProgram(this.program);
  const ctx=this.ctx;ctx.clearRect(0,0,this.canvas.width,this.canvas.height);ctx.drawImage(this.surface,0,0);
 }
 dispose(){this.disposed=true;const gl=this.gl;for(const b of this.buffers)gl.deleteBuffer(b);gl.deleteTexture(this.texture);gl.deleteProgram(this.program);
  if(this.gpu){for(const t of [this.geometryTexture,this.cellTexture,this.cellInfoTexture,this.shadeTexture,this.atlasTexture])gl.deleteTexture(t);gl.deleteRenderbuffer(this.depthBuffer);gl.deleteFramebuffer(this.geometryFBO);gl.deleteFramebuffer(this.cellFBO);gl.deleteProgram(this.cellProgram);gl.deleteProgram(this.glyphProgram);gl.deleteVertexArray(this.geometryVAO);gl.deleteVertexArray(this.emptyVAO);}
  gl.getExtension('WEBGL_lose_context')?.loseContext();}
}
