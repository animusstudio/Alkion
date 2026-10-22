// Compose approved outlined glyphs without changing their internal geometry.
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {dirname,join} from 'node:path';
import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const root=join(dirname(fileURLToPath(import.meta.url)),'..');
const directory=join(root,'assets/icon');
const source=await readFile(join(directory,'clean-arm-characters.svg'),'utf8');
// Remove only the source's black plate; paths and glyph placement stay verbatim.
const plate='<rect width="1000" height="1000" fill="#000"/>';
if(source.split(plate).length!==2||source.includes('<image')||source.includes('<text'))throw Error('Unexpected character master');
const art=source.replace(/^<svg[^>]*>/,'').replace(/<\/svg>\s*$/,'').replace(plate,'');
const browser=await chromium.launch({headless:true,...(process.env.CHROMIUM_PATH?{executablePath:process.env.CHROMIUM_PATH}:{}),args:['--disable-gpu']});
try {
 const page=await browser.newPage({deviceScaleFactor:1});
 await page.setViewportSize({width:1000,height:1000});
 await page.setContent(`<style>html,body{margin:0;background:transparent}</style><svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000">${art}</svg>`);
 const radius=await page.evaluate(()=>Math.max(...[...document.querySelectorAll('use')].flatMap(node=>{
  const r=node.getBoundingClientRect();return [[r.left,r.top],[r.right,r.top],[r.left,r.bottom],[r.right,r.bottom]].map(([x,y])=>Math.hypot(x-500,y-500));
 })));
 // All glyph bounding-box corners fit in a 66dp circle on a 108dp layer,
 // with an extra 2% margin. Android applies no second inset in the config.
 const adaptiveScale=.98*(66/108)*500/radius;
 const legacyScale=adaptiveScale*108/72;
 const files=[];
 for(const [name,scale,background]of [['alkion-foreground-1024',adaptiveScale,false],['alkion-icon-1024',legacyScale,true]]){
  const body=`<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1000 1000">${background?plate:''}<g transform="translate(500 500) scale(${scale.toFixed(9)}) translate(-500 -500)">${art}</g></svg>`;
  await page.setViewportSize({width:1024,height:1024});
  await page.setContent(`<style>html,body{margin:0;background:transparent}</style>${body}`);
  await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  const png=await page.screenshot({omitBackground:true});
  await writeFile(join(directory,name+'.png'),png);
  files.push({file:name+'.png',width:1024,height:1024,sha256:createHash('sha256').update(png).digest('hex')});
 }
 await writeFile(join(directory,'generation.json'),JSON.stringify({source:'clean-arm-characters.svg',source_sha256:createHash('sha256').update(source).digest('hex'),glyph_bound_radius:radius,adaptive_scale:adaptiveScale,legacy_scale:legacyScale,adaptive_layer_dp:108,safe_circle_dp:66,safe_margin:0.02,generator_inset_percent:0,files},null,2)+'\n');
 console.log('Composed transparent adaptive foreground and opaque legacy icon from approved glyphs.');
} finally {await browser.close();}
