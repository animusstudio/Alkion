import {glyphAlphabet,tonalGlyphs,samplingPitch,columnPhase,glyphCoverage,sampleSurfaceCell,materialGlyph,materialAlpha,regionColor} from './material.js';
import {bodyFit} from './geometry.js';
import {posedMesh} from './pose-geometry.js';

export async function loadMesh(){
 const response=await fetch('assets/body.mesh.json');if(!response.ok)throw new Error('Body mesh metadata unavailable');
 const manifest=await response.json();if(manifest.version!==1||manifest.binary!=='body.mesh.bin')throw new Error('Unsupported body mesh');
 const binary=await fetch('assets/body.mesh.bin');if(!binary.ok)throw new Error('Body mesh unavailable');
 const bytes=await binary.arrayBuffer(),data={manifest};
 const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),n=>n.toString(16).padStart(2,'0')).join('');
 if(hash!==manifest.sha256)throw new Error('Body mesh integrity mismatch');
 const types={'<f4':Float32Array,'<u4':Uint32Array,'|u1':Uint8Array};
 for(const [name,a] of Object.entries(manifest.attributes)){
  const Type=types[a.type];if(!Type||!Number.isSafeInteger(a.count)||a.count<=0||a.byteOffset<0||a.byteOffset%Type.BYTES_PER_ELEMENT||a.byteOffset+a.count*Type.BYTES_PER_ELEMENT>bytes.byteLength)throw new Error('Invalid body mesh attribute');
  data[name]=new Type(bytes,a.byteOffset,a.count);
 }
 if(data.positions.length!==manifest.vertices*3||data.normals.length!==data.positions.length||data.uv.length!==manifest.vertices*2||data.indices.length!==manifest.triangles*3)throw new Error('Body mesh layout mismatch');
 const masks=new Image();masks.src='assets/regions.png';await masks.decode();data.masks=masks;return posedMesh(data);
}

const diagnosticColors=[[118,124,138],[255,105,70],[100,165,255],[240,190,70],[140,210,100],[200,140,240],[70,205,200],[245,130,190],[170,180,250]];

/** A real indexed depth-buffered surface sampled into character cells. */
export class VolumeRenderer{
 constructor(canvas,mesh,compact=false){
  this.canvas=canvas;this.mesh=mesh;this.compact=compact;this.drawCount=0;this.glyphCount=0;
  this.ctx=canvas.getContext('2d');if(!this.ctx)throw new Error('Canvas unavailable');
  this.surface=document.createElement('canvas');const gl=this.gl=this.surface.getContext('webgl',{alpha:true,antialias:false,preserveDrawingBuffer:true});
  if(!gl||!gl.getExtension('OES_element_index_uint'))throw new Error('Indexed graphics unavailable');
  const compile=(type,source)=>{const shader=gl.createShader(type);gl.shaderSource(shader,source);gl.compileShader(shader);if(!gl.getShaderParameter(shader,gl.COMPILE_STATUS))throw new Error(gl.getShaderInfoLog(shader));return shader;};
  const vs=compile(gl.VERTEX_SHADER,`
   attribute vec3 position;attribute vec3 normal;attribute vec2 uv;
   uniform float yaw;uniform float aspect;uniform float fit;uniform float depthRange;
   varying vec3 viewNormal;varying vec2 sourceUV;varying float sourceDepth;
   void main(){float c=cos(yaw),s=sin(yaw);vec3 p=vec3(c*position.x+s*position.z,position.y,-s*position.x+c*position.z);
    sourceDepth=.5+p.z/(2.0*depthRange);viewNormal=vec3(c*normal.x+s*normal.z,normal.y,-s*normal.x+c*normal.z);sourceUV=uv;
    gl_Position=vec4(p.x*fit/aspect,p.y*fit,-p.z/depthRange,1.0);}`);
  const fs=compile(gl.FRAGMENT_SHADER,`
   precision mediump float;uniform sampler2D sourceMasks;
   varying vec3 viewNormal;varying vec2 sourceUV;varying float sourceDepth;
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
    gl_FragColor=vec4(shade,mask.r,sourceDepth,1.0);}`);
  const program=this.program=gl.createProgram();gl.attachShader(program,vs);gl.attachShader(program,fs);gl.linkProgram(program);
  if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw new Error(gl.getProgramInfoLog(program));
  gl.deleteShader(vs);gl.deleteShader(fs);gl.useProgram(program);this.buffers=[];
  for(const [name,size,data] of [['position',3,mesh.positions],['normal',3,mesh.normals],['uv',2,mesh.uv]]){
   const buffer=gl.createBuffer();this.buffers.push(buffer);gl.bindBuffer(gl.ARRAY_BUFFER,buffer);gl.bufferData(gl.ARRAY_BUFFER,data,gl.STATIC_DRAW);
   const location=gl.getAttribLocation(program,name);gl.enableVertexAttribArray(location);gl.vertexAttribPointer(location,size,gl.FLOAT,false,0,0);
  }
  const index=gl.createBuffer();this.buffers.push(index);gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,index);gl.bufferData(gl.ELEMENT_ARRAY_BUFFER,mesh.indices,gl.STATIC_DRAW);
  this.texture=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,this.texture);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
  gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,mesh.masks);gl.uniform1i(gl.getUniformLocation(program,'sourceMasks'),0);
  this.fitLocation=gl.getUniformLocation(program,'fit');
  gl.uniform1f(gl.getUniformLocation(program,'depthRange'),mesh.radius);
  this.yawLocation=gl.getUniformLocation(program,'yaw');this.aspectLocation=gl.getUniformLocation(program,'aspect');
  gl.enable(gl.DEPTH_TEST);gl.depthFunc(gl.LESS);gl.disable(gl.BLEND);gl.disable(gl.DITHER);
  this.atlas=document.createElement('canvas');this.lost=false;
  this.surface.addEventListener('webglcontextlost',event=>{event.preventDefault();this.lost=true;canvas.dispatchEvent(new Event('renderfailure'));});
 }
 resize(){
  const width=this.canvas.clientWidth,height=this.canvas.clientHeight;if(!width||!height)return false;
  const dpr=Math.min(devicePixelRatio||1,2),w=Math.round(width*dpr),h=Math.round(height*dpr);
  if(w===this.canvas.width&&h===this.canvas.height&&this.pixels)return true;
  this.canvas.width=w;this.canvas.height=h;const pitch=this.compact?samplingPitch.compact:samplingPitch.large;
  this.cols=Math.max(1,Math.round(width/pitch));this.rows=Math.max(1,Math.round(height/(pitch/samplingPitch.aspect)));
  this.surface.width=this.cols*3;this.surface.height=this.rows*3;this.gl.viewport(0,0,this.surface.width,this.surface.height);
  this.pixels=new Uint8Array(this.surface.width*this.surface.height*4);this.atlasKey='';return true;
 }
 buildAtlas(muscles,theme){
  const key=JSON.stringify([muscles,theme,this.cols,this.rows,this.canvas.width]);if(key===this.atlasKey)return;this.atlasKey=key;
  this.cellW=this.canvas.width/this.cols;this.cellH=this.canvas.height/this.rows;this.tileW=Math.ceil(this.cellW+3);this.tileH=Math.ceil(this.cellH+3);
  this.atlas.width=this.tileW*glyphAlphabet.length;this.atlas.height=this.tileH*this.mesh.manifest.regions.length;
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
  this.mesh.manifest.regions.forEach((region,i)=>{
   ink.fillStyle=regionColor(region,muscles,theme);
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
  ctx.putImageData(coverage,0,0);
 }
 draw(yaw,muscles,theme,mode='characters'){
  if(this.lost)throw new Error('Graphics context lost');if(!this.resize())return;
  this.buildAtlas(muscles,theme);const gl=this.gl;gl.useProgram(this.program);gl.uniform1f(this.yawLocation,yaw);const aspect=this.canvas.width/this.canvas.height;gl.uniform1f(this.aspectLocation,aspect);gl.uniform1f(this.fitLocation,bodyFit(this.mesh,aspect));
  gl.clearColor(0,0,0,0);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);gl.drawElements(gl.TRIANGLES,this.mesh.indices.length,gl.UNSIGNED_INT,0);
  gl.readPixels(0,0,this.surface.width,this.surface.height,gl.RGBA,gl.UNSIGNED_BYTE,this.pixels);
  if(mode!=='characters'){this.drawDiagnostic(mode,theme);return;}
  const ctx=this.ctx,pixels=this.pixels,stride=this.surface.width;ctx.clearRect(0,0,this.canvas.width,this.canvas.height);
  let count=0,signature=2166136261;const histogram={};
  for(let row=0;row<this.rows;row++)for(let col=0;col<this.cols;col++){
   const phase=columnPhase(col);
   const cell=sampleSurfaceCell(pixels,stride,this.surface.height,col,row,this.compact,phase);if(!cell)continue;
   const glyph=materialGlyph(cell.shade,col,row,cell);if(glyph===' ')continue;
   const g=glyphAlphabet.indexOf(glyph);
   ctx.globalAlpha=materialAlpha(cell.shade,theme,cell.coverage,this.compact);
   ctx.drawImage(this.atlas,g*this.tileW,cell.region*this.tileH,this.tileW,this.tileH,col*this.cellW+(this.cellW-this.tileW)/2,(row+phase/3)*this.cellH+(this.cellH-this.tileH)/2,this.tileW,this.tileH);
   count++;histogram[glyph]=(histogram[glyph]||0)+1;
   signature=Math.imul(signature^cell.at^cell.shade^glyph.charCodeAt(0)^phase,16777619)>>>0;
  }
  ctx.globalAlpha=1;this.drawCount++;this.glyphCount=count;this.canvas.dataset.glyphCount=String(count);this.canvas.dataset.materialSignature=String(signature);this.canvas.dataset.glyphHistogram=JSON.stringify(histogram);this.canvas.dataset.yaw=String(yaw);
 }
 drawDiagnostic(mode,theme){
  const width=this.surface.width,height=this.surface.height,pixels=new Uint8ClampedArray(width*height*4);
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
 dispose(){for(const b of this.buffers)this.gl.deleteBuffer(b);this.gl.deleteTexture(this.texture);this.gl.deleteProgram(this.program);}
}
