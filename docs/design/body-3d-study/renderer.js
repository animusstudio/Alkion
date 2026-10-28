/** Offline ASCII material over genuine indexed 3D geometry. Workout-agnostic. */
export class BodyRenderer {
  constructor(canvas, mesh) {
    this.canvas = canvas;
    this.context = canvas.getContext('2d');
    if (!this.context) throw new Error('Canvas 2D unavailable');
    this.surface = document.createElement('canvas');
    this.gl = this.surface.getContext('webgl', {alpha:true, antialias:false, preserveDrawingBuffer:true});
    if (!this.gl) throw new Error('WebGL unavailable');
    const gl = this.gl;
    const shader = (type, source) => {
      const s = gl.createShader(type); gl.shaderSource(s, source); gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
      return s;
    };
    const vertex = shader(gl.VERTEX_SHADER, `
      attribute vec3 position; attribute vec3 normal; attribute float region;
      uniform float yaw; uniform float aspect;
      varying vec3 viewNormal; varying float part;
      void main() {
        float c=cos(yaw), s=sin(yaw);
        vec3 p=vec3(position.x*c+position.z*s,position.y,-position.x*s+position.z*c);
        viewNormal=vec3(normal.x*c+normal.z*s,normal.y,-normal.x*s+normal.z*c);
        part=region;
        gl_Position=vec4(p.x*0.94/aspect,p.y*0.94,-p.z*0.5,1.0);
      }`);
    const fragment = shader(gl.FRAGMENT_SHADER, `
      precision mediump float; varying vec3 viewNormal; varying float part;
      void main() {
        vec3 n=normalize(viewNormal);
        float diffuse=max(0.0,dot(n,normalize(vec3(-0.45,0.65,1.0))));
        float reflected=max(0.0,dot(n,normalize(vec3(0.7,0.1,0.5))));
        float shade=clamp(0.27+diffuse*0.61+reflected*0.12,0.0,1.0);
        gl_FragColor=vec4(shade,part/255.0,0.0,1.0);
      }`);
    this.program = gl.createProgram(); gl.attachShader(this.program, vertex); gl.attachShader(this.program, fragment); gl.linkProgram(this.program);
    if (!gl.getProgramParameter(this.program,gl.LINK_STATUS)) throw new Error('Shader link failed');
    gl.useProgram(this.program);
    const data = new Float32Array(mesh.indices.length*7);
    mesh.indices.forEach((vertex,index) => {
      const at=index*7;
      data.set(mesh.positions.slice(vertex*3,vertex*3+3),at);
      data.set(mesh.normals.slice(vertex*3,vertex*3+3),at+3);
      data[at+6]=mesh.triangleRegions[Math.floor(index/3)];
    });
    this.buffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,this.buffer);gl.bufferData(gl.ARRAY_BUFFER,data,gl.STATIC_DRAW);
    for (const [name,size,offset] of [['position',3,0],['normal',3,12],['region',1,24]]) {
      const at=gl.getAttribLocation(this.program,name);gl.enableVertexAttribArray(at);gl.vertexAttribPointer(at,size,gl.FLOAT,false,28,offset);
    }
    this.count=mesh.indices.length;this.regions=mesh.regions;
    this.yawUniform=gl.getUniformLocation(this.program,'yaw');this.aspectUniform=gl.getUniformLocation(this.program,'aspect');
    gl.enable(gl.DEPTH_TEST);gl.depthFunc(gl.LEQUAL);gl.disable(gl.BLEND);
    this.atlas=document.createElement('canvas');this.atlasKey='';this.drawCount=0;
    this.lost=false;
    this.surface.addEventListener('webglcontextlost', event=>{event.preventDefault();this.lost=true;canvas.dispatchEvent(new Event('renderfailure'));});
  }
  resize() {
    const box=this.canvas.getBoundingClientRect();
    const ratio=Math.min(2,window.devicePixelRatio||1);
    const w=Math.round(box.width*ratio), h=Math.round(box.height*ratio);
    if(this.canvas.width===w&&this.canvas.height===h)return;
    this.canvas.width=w;this.canvas.height=h;
    const compact=box.height<400;
    this.cols=Math.max(48,Math.round(box.width/(compact?2.6:4)));this.rows=Math.max(80,Math.round(box.height/(compact?3.7:5.5)));
    this.surface.width=this.cols;this.surface.height=this.rows;
    this.pixels=new Uint8Array(this.cols*this.rows*4);
    this.gl.viewport(0,0,this.cols,this.rows);this.atlasKey='';
  }
  buildAtlas(scores,theme,partitionView) {
    const key=JSON.stringify([scores,theme,partitionView,this.canvas.width,this.canvas.height]);
    if(key===this.atlasKey)return;
    this.atlasKey=key;
    const cellW=this.canvas.width/this.cols,cellH=this.canvas.height/this.rows;
    const tileW=Math.ceil(cellW+2),tileH=Math.ceil(cellH+2);
    this.tileW=tileW;this.tileH=tileH;this.cellW=cellW;this.cellH=cellH;
    const ramp='.:;-=+xX80S#@';this.ramp=ramp;
    this.atlas.width=tileW*ramp.length;this.atlas.height=tileH*this.regions.length;
    const ctx=this.atlas.getContext('2d');
    ctx.font=`400 ${cellH*1.13}px 'Space Mono',monospace`;ctx.textAlign='center';ctx.textBaseline='middle';
    const neutral=theme==='dark'?[240,240,245]:[50,54,66];
    const accent=theme==='dark'?[255,104,53]:[168,45,0];
    this.regions.forEach((region,i)=>{
      let score=scores[region]?.score||0;
      // Partition inspection uses canonical accent at uniform strength. It is
      // explicitly an asset mask, never presented as computed workout data.
      if(partitionView)score=partitionView===region?1:0;
      const rgb=neutral.map((v,k)=>Math.round(v+(accent[k]-v)*score));
      if(region==='trunks')rgb.splice(0,3,...(theme==='dark'?[132,138,151]:[109,116,129]));
      for(let j=0;j<ramp.length;j++){
        ctx.fillStyle=`rgb(${rgb.join(',')})`;
        ctx.fillText(ramp[j],j*tileW+tileW/2,i*tileH+tileH/2);
      }
    });
  }
  draw(yaw,scores,theme,partitionView='') {
    if(this.lost)throw new Error('Graphics context unavailable');
    this.resize();this.buildAtlas(scores,theme,partitionView);
    const gl=this.gl;
    gl.useProgram(this.program);gl.uniform1f(this.yawUniform,yaw);gl.uniform1f(this.aspectUniform,this.canvas.width/this.canvas.height);
    gl.clearColor(0,0,0,0);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);gl.drawArrays(gl.TRIANGLES,0,this.count);
    gl.readPixels(0,0,this.cols,this.rows,gl.RGBA,gl.UNSIGNED_BYTE,this.pixels);
    const ctx=this.context;ctx.clearRect(0,0,this.canvas.width,this.canvas.height);
    const w=this.cellW,h=this.cellH;
    for(let y=0;y<this.rows;y++)for(let x=0;x<this.cols;x++){
      const at=((this.rows-1-y)*this.cols+x)*4;
      if(!this.pixels[at+3])continue;
      const glyph=Math.min(this.ramp.length-1,Math.floor(this.pixels[at]/256*this.ramp.length));
      const region=Math.min(this.regions.length-1,this.pixels[at+1]);
      ctx.drawImage(this.atlas,glyph*this.tileW,region*this.tileH,this.tileW,this.tileH,x*w-1,y*h-1,this.tileW,this.tileH);
    }
    this.drawCount++;
  }
  dispose(){this.gl.deleteBuffer(this.buffer);this.gl.deleteProgram(this.program);}
}
