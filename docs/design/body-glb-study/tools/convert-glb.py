#!/usr/bin/env python3
"""Validate a supplied GLB and preserve its full surface in a private study asset.

Only embedded, uncompressed triangle GLBs are accepted. No URLs are fetched.
Authored region seeds are a separate private JSON input, bound to the GLB hash.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import struct

import numpy as np
from PIL import Image, ImageDraw

REGIONS = [None, 'chest', 'back', 'shoulders', 'quads', 'hamstrings', 'calves', 'biceps', 'triceps']
TYPES = {5120: '<i1', 5121: '<u1', 5122: '<i2', 5123: '<u2', 5125: '<u4', 5126: '<f4'}
WIDTHS = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load_glb(path):
    raw = Path(path).read_bytes()
    require(len(raw) >= 20, 'Truncated GLB')
    magic, version, length = struct.unpack_from('<4sII', raw)
    require(magic == b'glTF' and version == 2 and length == len(raw), 'Invalid GLB header')
    chunks, offset = [], 12
    while offset < len(raw):
        require(offset + 8 <= len(raw), 'Truncated chunk header')
        size, kind = struct.unpack_from('<II', raw, offset)
        require(size % 4 == 0 and offset + 8 + size <= len(raw), 'Invalid chunk bounds')
        chunks.append((kind, raw[offset + 8:offset + 8 + size]))
        offset += 8 + size
    require([kind for kind, _ in chunks] == [0x4E4F534A, 0x004E4942], 'Expected JSON and embedded BIN')
    doc, binary = json.loads(chunks[0][1]), chunks[1][1]
    require(doc['asset']['version'] == '2.0' and not doc.get('extensionsRequired'), 'Unsupported glTF version/extensions')
    require(len(doc['buffers']) == 1 and not doc['buffers'][0].get('uri'), 'Only one embedded buffer accepted')
    size = doc['buffers'][0]['byteLength']
    require(size <= len(binary) <= size + 3, 'Invalid buffer length')
    for view in doc['bufferViews']:
        start, count = view.get('byteOffset', 0), view['byteLength']
        require(view.get('buffer', 0) == 0 and start >= 0 and count > 0 and start + count <= size, 'Invalid bufferView')
    cache = {}

    def accessor(index):
        if index in cache:
            return cache[index]
        a = doc['accessors'][index]
        require(not a.get('sparse') and a['type'] in WIDTHS and a['componentType'] in TYPES, 'Unsupported accessor')
        v = doc['bufferViews'][a['bufferView']]
        dt, width = np.dtype(TYPES[a['componentType']]), WIDTHS[a['type']]
        stride, start, count = v.get('byteStride', dt.itemsize * width), a.get('byteOffset', 0), a['count']
        require(count > 0 and start >= 0 and start % dt.itemsize == 0, 'Invalid accessor count/offset')
        require(stride >= dt.itemsize * width and stride % dt.itemsize == 0, 'Invalid accessor stride')
        require(start + (count - 1) * stride + width * dt.itemsize <= v['byteLength'], 'Accessor exceeds bufferView')
        values = np.ndarray((count, width), dtype=dt, buffer=binary, offset=v.get('byteOffset', 0) + start, strides=(stride, dt.itemsize)).copy()
        require(np.isfinite(values).all(), 'Non-finite accessor')
        for key, operation in [('min', np.min), ('max', np.max)]:
            if key in a:
                require(np.allclose(operation(values, axis=0), a[key], atol=2e-6), 'Accessor bounds mismatch')
        if a.get('normalized'):
            require(a['componentType'] in (5120, 5121, 5122, 5123), 'Invalid normalized accessor')
            info = np.iinfo(dt)
            values = np.maximum(values.astype(np.float64) / info.max, -1)
        cache[index] = values
        return values

    # Validate every declared accessor, including tangents not used by the study.
    for i in range(len(doc['accessors'])):
        accessor(i)
    positions, normals, uvs, indices, records = [], [], [], [], []
    active, seen = set(), set()

    def visit(index, parent):
        require(index not in active, 'Scene cycle')
        require(index not in seen, 'Instanced/repeated nodes unsupported by this bounded converter')
        active.add(index)
        seen.add(index)
        node = doc['nodes'][index]
        require('skin' not in node, 'Skinned mesh unsupported')
        if 'matrix' in node:
            require(not any(k in node for k in ('translation', 'rotation', 'scale')), 'Mixed node transforms')
            local = np.array(node['matrix'], dtype=np.float64).reshape(4, 4).T
        else:
            x, y, z, w = node.get('rotation', [0, 0, 0, 1])
            require(abs(x*x+y*y+z*z+w*w-1) < 1e-5, 'Non-unit quaternion')
            local = np.eye(4)
            local[:3, :3] = [[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
                             [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
                             [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]]
            local[:3, :3] @= np.diag(node.get('scale', [1, 1, 1]))
            local[:3, 3] = node.get('translation', [0, 0, 0])
        world = parent @ local
        require(np.isfinite(world).all() and np.allclose(world[3], [0, 0, 0, 1]), 'Non-affine transform')
        determinant = np.linalg.det(world[:3, :3])
        require(abs(determinant) > 1e-12, 'Singular scene transform')
        if 'mesh' in node:
            for primitive in doc['meshes'][node['mesh']]['primitives']:
                require(primitive.get('mode', 4) == 4 and not primitive.get('extensions') and not primitive.get('targets'), 'Only static uncompressed triangles accepted')
                attrs = primitive['attributes']
                p, n, uv = (accessor(attrs[key]) for key in ('POSITION', 'NORMAL', 'TEXCOORD_0'))
                require(p.shape == n.shape and p.shape[1] == 3 and uv.shape == (len(p), 2), 'Invalid vertex shapes')
                ia = doc['accessors'][primitive['indices']]
                require(ia['type'] == 'SCALAR' and ia['componentType'] in (5121, 5123, 5125), 'Invalid index type')
                ids = accessor(primitive['indices']).reshape(-1).astype(np.uint32)
                require(len(ids) % 3 == 0 and int(ids.max()) < len(p), 'Invalid triangle indices')
                require(np.all((uv >= 0) & (uv <= 1)), 'UV wrap outside supplied atlas unsupported')
                pn = p.astype(np.float64) @ world[:3, :3].T + world[:3, 3]
                nn = n.astype(np.float64) @ np.linalg.inv(world[:3, :3])
                norms = np.linalg.norm(nn, axis=1)
                require(np.all(norms > .001), 'Zero source normal')
                nn /= norms[:, None]
                if determinant < 0:
                    ids = ids.reshape(-1, 3)[:, [0, 2, 1]].reshape(-1)
                start = sum(len(item) for item in positions)
                records.append({'node': index, 'mesh': node['mesh'], 'vertices': len(p), 'triangles': len(ids)//3,
                                'worldMatrix': world.tolist(), 'sourceNormalLengthRange': [float(norms.min()), float(norms.max())]})
                positions.append(pn); normals.append(nn); uvs.append(uv); indices.append(ids + start)
        for child in node.get('children', []):
            visit(child, world)
        active.remove(index)

    require(not doc.get('animations'), 'Animated GLB unsupported')
    for node in doc['scenes'][doc.get('scene', 0)]['nodes']:
        visit(node, np.eye(4))
    require(bool(positions), 'Empty scene')
    p = np.concatenate(positions)
    low, high = p.min(axis=0), p.max(axis=0)
    height = high[1] - low[1]
    require(height > 0, 'Empty vertical bounds')
    center = (low + high) / 2
    # One uniform affine normalization only: original proportions are preserved.
    p = (p - center) * (2 / height)
    result = {'positions': p.astype('<f4'), 'normals': np.concatenate(normals).astype('<f4'),
              'uv': np.concatenate(uvs).astype('<f4'), 'indices': np.concatenate(indices).astype('<u4')}
    materials = {primitive.get('material') for mesh in doc['meshes'] for primitive in mesh['primitives']}
    require(len(materials) == 1 and None not in materials, 'Expected one source material')
    texture_index = doc['materials'][next(iter(materials))]['pbrMetallicRoughness']['baseColorTexture']['index']
    source = doc['images'][doc['textures'][texture_index]['source']]
    require('uri' not in source and source['mimeType'] in ('image/jpeg', 'image/png'), 'Only embedded raster atlas accepted')
    view = doc['bufferViews'][source['bufferView']]
    atlas_bytes = binary[view.get('byteOffset', 0):view.get('byteOffset', 0)+view['byteLength']]
    atlas = Image.open(io.BytesIO(atlas_bytes)).convert('RGB')
    metadata = {'sourceSha256': digest(raw), 'sourceBytes': len(raw), 'atlasSha256': digest(atlas_bytes),
                'sourceWorldBounds': [low.tolist(), high.tolist()], 'center': center.tolist(), 'uniformScale': 2 / height,
                'chunks': records}
    return result, atlas, metadata


def connected_seed_mask(atlas, specification):
    """Connected source-color patch at each authored UV seed, never global RGB."""
    rgb = np.array(atlas, dtype=np.int16)
    height, width = rgb.shape[:2]
    output = np.zeros((height, width), dtype=np.uint8)
    records = []
    for seed in specification['seeds']:
        group = REGIONS.index(seed['group'])
        require(group > 0, 'Neutral is implicit')
        x, y = (int(round(v * (d-1))) for v, d in zip(seed['uv'], [width, height]))
        require(2 <= x < width-2 and 2 <= y < height-2, 'Seed outside atlas interior')
        if output[y, x] == group:
            continue  # Two source lobes may already be the same connected patch.
        require(output[y, x] == 0, 'Conflicting region seed')
        color = np.median(rgb[y-2:y+3, x-2:x+3], axis=(0, 1))
        threshold = specification.get('rgbTolerance', 24)
        match = (np.max(np.abs(rgb - color), axis=2) <= threshold).astype(np.uint8)
        require(match[y, x] == 1, f'Seed lies on printed label or border: {seed}')
        image = Image.fromarray(match).copy()
        ImageDraw.floodfill(image, (x, y), 2, thresh=0)
        patch = np.array(image) == 2
        require(patch.sum() >= 100, f'Seed missed source patch: {seed}')
        require(patch.sum() < width*height*.15, f'Unbounded source patch: {seed}')
        yy, xx = np.where(patch)
        # Fill only enclosed near-neutral label ink, not neighboring color regions.
        left, right, top, bottom = max(0, int(xx.min())-1), min(width, int(xx.max())+2), max(0, int(yy.min())-1), min(height, int(yy.max())+2)
        tile = patch[top:bottom, left:right]
        exterior = Image.fromarray(tile.astype(np.uint8)).copy()
        ImageDraw.floodfill(exterior, (0, 0), 2, thresh=0)
        holes = np.array(exterior) == 0
        hole_rgb = rgb[top:bottom, left:right]
        direction = 255 - color
        alpha = np.clip(np.sum((hole_rgb-color)*direction, axis=2) / np.sum(direction*direction), 0, 1)
        white = np.max(np.abs(hole_rgb - (color + alpha[..., None]*direction)), axis=2) <= 12
        # Antialiased text pixels may retain patch tint, but only already-enclosed
        # pixels within this verified patch can be filled.
        patch[top:bottom, left:right] |= holes & (white | (np.max(np.abs(hole_rgb-color), axis=2) <= threshold*2))
        require(not np.any(patch & (output != 0) & (output != group)), f'Authored patches overlap: {seed}')
        output[patch] = group
        records.append({'label': seed['label'], 'group': seed['group'], 'uv': seed['uv'], 'pixels': int(patch.sum()),
                        'sourceColor': color.tolist()})
    return output, records


def convert(input_path, region_path, output_path):
    output_path = Path(output_path)
    # The converter and preview stager refuse any destination inside this checkout.
    repo = Path(__file__).resolve().parents[4]
    require(not output_path.resolve().is_relative_to(repo), 'Derived assets must be outside the source checkout')
    arrays, atlas, manifest = load_glb(input_path)
    region_bytes = Path(region_path).read_bytes()
    spec = json.loads(region_bytes)
    require(spec['sourceSha256'] == manifest['sourceSha256'], 'Region recipe belongs to another GLB')
    mask, regions = connected_seed_mask(atlas, spec)
    output_path.mkdir(parents=True, exist_ok=True)
    Image.fromarray(mask).save(output_path/'regions.png', optimize=False)
    # Private diagnostic only. Runtime never loads the source texture.
    palette = np.array([[100,100,100],[255,105,70],[100,165,255],[240,190,70],[140,210,100],
                        [200,140,240],[70,205,200],[245,130,190],[170,180,250]], dtype=np.uint8)
    diagnostic = np.array(atlas)//3 + (palette[mask].astype(np.uint16)*2//3).astype(np.uint8)
    Image.fromarray(diagnostic).save(output_path/'region-diagnostic.png')
    # Exact centroid identity is an additional offline mapping receipt; renderer
    # samples the same immutable source UV mask per fragment.
    uv = arrays['uv'][arrays['indices'].reshape(-1,3)].mean(axis=1)
    x = np.minimum((uv[:,0]*mask.shape[1]).astype(int), mask.shape[1]-1)
    y = np.minimum((uv[:,1]*mask.shape[0]).astype(int), mask.shape[0]-1)
    arrays['regions'] = mask[y,x]
    attributes, chunks, cursor = {}, [], 0
    for name, values in arrays.items():
        values = np.ascontiguousarray(values)
        padding = (-cursor) % 4
        chunks.append(b'\0'*padding); cursor += padding
        raw = values.tobytes()
        attributes[name] = {'type': values.dtype.str, 'byteOffset': cursor, 'count': values.size}
        chunks.append(raw); cursor += len(raw)
    binary = b''.join(chunks)
    (output_path/'body.mesh.bin').write_bytes(binary)
    manifest.update({'version': 1, 'binary': 'body.mesh.bin', 'sha256': digest(binary), 'attributes': attributes,
                     'vertices': len(arrays['positions']), 'triangles': len(arrays['indices'])//3,
                     'regions': REGIONS, 'coordinates': 'glTF scene Y-up; centered; uniform height 2; +Z front',
                     'bounds': [arrays['positions'].min(axis=0).tolist(), arrays['positions'].max(axis=0).tolist()],
                     'regionRecipeSha256': digest(region_bytes), 'maskSha256': digest((output_path/'regions.png').read_bytes()),
                     'regionPatches': regions, 'regionTriangleCounts': {str(name): int(np.sum(arrays['regions']==i)) for i,name in enumerate(REGIONS)},
                     'method': 'Unmodified indexed source triangles and transformed source normals; one uniform normalization; authored connected UV patches'})
    (output_path/'body.mesh.json').write_text(json.dumps(manifest, indent=2, sort_keys=True)+'\n')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--regions', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    result = convert(args.input, args.regions, args.out)
    print(json.dumps({key: result[key] for key in ['sourceSha256', 'vertices', 'triangles', 'bounds', 'regionTriangleCounts']}, indent=2))
