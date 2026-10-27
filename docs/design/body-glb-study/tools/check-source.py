#!/usr/bin/env python3
"""Independent full-source geometry comparison and private asset verification."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--input', required=True, type=Path)
parser.add_argument('--regions', required=True, type=Path)
parser.add_argument('--assets', required=True, type=Path)
parser.add_argument('--reproduce', action='store_true')
args = parser.parse_args()
raw = args.input.read_bytes()
manifest = json.loads((args.assets/'body.mesh.json').read_text())
assert hashlib.sha256(raw).hexdigest() == manifest['sourceSha256']
assert hashlib.sha256(args.regions.read_bytes()).hexdigest() == manifest['regionRecipeSha256']
blob = (args.assets/'body.mesh.bin').read_bytes()
assert hashlib.sha256(blob).hexdigest() == manifest['sha256']
assert hashlib.sha256((args.assets/'regions.png').read_bytes()).hexdigest() == manifest['maskSha256']
arrays = {name: np.frombuffer(blob, dtype=a['type'], offset=a['byteOffset'], count=a['count']) for name,a in manifest['attributes'].items()}
size = struct.unpack_from('<I',raw,12)[0]
doc, binary = json.loads(raw[20:20+size]), raw[28+size:]

def accessor(index):
    a=doc['accessors'][index];v=doc['bufferViews'][a['bufferView']]
    dtype=np.dtype({5126:'<f4',5123:'<u2',5125:'<u4',5121:'u1'}[a['componentType']])
    width={'VEC3':3,'VEC2':2,'SCALAR':1}[a['type']]
    return np.ndarray((a['count'],width), dtype=dtype, buffer=binary, offset=v.get('byteOffset',0)+a.get('byteOffset',0),strides=(v.get('byteStride',width*dtype.itemsize),dtype.itemsize)).copy()

# Independent quaternion-vector formula rather than the converter's matrices.
def apply(values, node, normal=False):
    values=values.astype(np.float64)
    if 'matrix' in node:
        m=np.array(node['matrix']).reshape(4,4).T
        return values @ np.linalg.inv(m[:3,:3]) if normal else values @ m[:3,:3].T+m[:3,3]
    scale=np.array(node.get('scale',[1,1,1]));values=values/scale if normal else values*scale
    q=np.array(node.get('rotation',[0,0,0,1]));vector=q[:3]
    values=values+2*np.cross(vector,np.cross(vector,values)+q[3]*values)
    return values if normal else values+node.get('translation',[0,0,0])

ps,ns,uvs,ids=[],[],[],[]
def visit(index, ancestors):
    node=doc['nodes'][index]
    chain=[node]+ancestors
    if 'mesh' in node:
        for primitive in doc['meshes'][node['mesh']]['primitives']:
            p=accessor(primitive['attributes']['POSITION']);n=accessor(primitive['attributes']['NORMAL']);uv=accessor(primitive['attributes']['TEXCOORD_0'])
            i=accessor(primitive['indices']).reshape(-1).astype(np.uint32)
            for transform in chain:
                p=apply(p,transform);n=apply(n,transform,True)
            n/=np.linalg.norm(n,axis=1)[:,None]
            ids.append(i+sum(len(v) for v in ps));ps.append(p);ns.append(n);uvs.append(uv)
    for child in node.get('children',[]):visit(child,chain)
for index in doc['scenes'][doc.get('scene',0)]['nodes']:visit(index,[])
p=np.concatenate(ps);low,high=p.min(0),p.max(0)
expected=(p-(low+high)/2)*(2/(high[1]-low[1]))
actual=arrays['positions'].reshape(-1,3)
assert len(actual)==len(p)==manifest['vertices']
assert np.allclose(expected,actual,atol=1e-7,rtol=0), 'Source positions changed'
assert np.allclose(np.concatenate(ns),arrays['normals'].reshape(-1,3),atol=1e-7,rtol=0), 'Source normals changed'
assert np.array_equal(np.concatenate(ids),arrays['indices']), 'Source triangles changed'
assert np.array_equal(np.concatenate(uvs),arrays['uv'].reshape(-1,2)), 'Source UVs changed'
assert len(arrays['indices'])//3==manifest['triangles']
assert np.allclose(low,manifest['sourceWorldBounds'][0]) and np.allclose(high,manifest['sourceWorldBounds'][1])
mask=np.array(Image.open(args.assets/'regions.png'))
assert mask.min()==0 and mask.max()==8 and set(np.unique(mask))==set(range(9))
uv=arrays['uv'].reshape(-1,2)[arrays['indices'].reshape(-1,3)].mean(1)
x=np.minimum((uv[:,0]*mask.shape[1]).astype(int),mask.shape[1]-1);y=np.minimum((uv[:,1]*mask.shape[0]).astype(int),mask.shape[0]-1)
assert np.array_equal(mask[y,x],arrays['regions']), 'Triangle identity differs from fixed UV mask'
for seed in json.loads(args.regions.read_text())['seeds']:
    x,y=[round(v*(d-1)) for v,d in zip(seed['uv'],[mask.shape[1],mask.shape[0]])]
    assert mask[y,x]==manifest['regions'].index(seed['group']), seed
tri=actual[arrays['indices'].reshape(-1,3)]
area=np.linalg.norm(np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]),axis=1)
print(f"PASS: source hash; all {len(ps)} chunks; {len(actual):,} vertices; {len(tri):,} triangles; independent scene transform/normals/UV/index comparison; 8 groups + neutral; source-fixed identity.")
assert np.array_equal(actual.min(axis=0), manifest['bounds'][0]) and np.array_equal(actual.max(axis=0), manifest['bounds'][1]), 'Converted bounds changed'
print(f"Source exactly zero-area triangles: {np.count_nonzero(area == 0)}; tiny nonzero triangles: {np.count_nonzero((area > 0) & (area < 1e-14))}; every triangle retained. No watertightness or connectedness requirement imposed.")
print('Canonical centroid counts:',manifest['regionTriangleCounts'])
if args.reproduce:
    spec=importlib.util.spec_from_file_location('converter',Path(__file__).with_name('convert-glb.py'))
    converter=importlib.util.module_from_spec(spec);spec.loader.exec_module(converter)
    with tempfile.TemporaryDirectory(prefix='body-glb-reproduce-') as temporary:
        converter.convert(args.input,args.regions,Path(temporary))
        for name in ['body.mesh.bin','body.mesh.json','regions.png','region-diagnostic.png']:
            assert (Path(temporary)/name).read_bytes()==(args.assets/name).read_bytes(),name
    print('PASS: independent-directory conversion reproduces every asset byte-for-byte.')
