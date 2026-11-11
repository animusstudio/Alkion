#!/usr/bin/env python3
"""Reproduce Alkion's bundled Iconoir subset without network access.

Inputs and source digests live in tool/iconoir/manifest.json. --check is read-only.
Upstream originals are the regular outline set; `*-solid` names come from the
same revision's solid set.
Only stroke-width changes; geometry, fills, caps and joins are retained.
"""
import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

APP = Path(__file__).resolve().parents[1]
INPUT = APP / 'tool/iconoir'
OUTPUT = APP / 'assets/icons'
TIERS = ('1.25', '1.0')
SVG = 'http://www.w3.org/2000/svg'
ET.register_namespace('', SVG)
PAINT_ELEMENTS = {'path', 'circle', 'ellipse', 'rect', 'line', 'polyline', 'polygon'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def normalize(data, stroke):
    root = ET.fromstring(data)
    if root.attrib.get('viewBox') != '0 0 24 24':
        raise ValueError('Expected the 24-unit viewBox')

    def visit(node, inherited_stroke='none'):
        # These pinned inputs use presentation attributes. Fail closed if a
        # future source requires CSS handling rather than silently changing it.
        if 'style' in node.attrib:
            raise ValueError('Inline CSS is not part of the pinned subset')
        effective_stroke = node.attrib.get('stroke', inherited_stroke)
        if ('stroke-width' in node.attrib or
                (node.tag.split('}')[-1] in PAINT_ELEMENTS and effective_stroke != 'none')):
            node.set('stroke-width', stroke)
        for child in node:
            visit(child, effective_stroke)

    root.set('stroke-width', stroke)
    visit(root)
    return ET.tostring(root, encoding='utf-8') + b'\n'


def outputs():
    manifest = json.loads((INPUT / 'manifest.json').read_text())
    assets = [*manifest['assets'], *manifest.get('custom_assets', [])]
    expected_sources = {a['source'] for a in assets} | {manifest['license']['source']}
    actual_sources = {str(p.relative_to(INPUT)) for folder in ['sources', 'custom']
                      for p in (INPUT / folder).glob('*') if p.is_file()}
    for asset in manifest.get('custom_assets', []):
        if (not asset['name'].startswith('alkion-') or
                not asset['source'].startswith('custom/') or
                asset.get('spdx') != 'AGPL-3.0-only' or
                not asset.get('author') or not asset.get('provenance') or 'url' in asset):
            raise ValueError('Custom authorship must remain separate from Iconoir')
    if actual_sources != expected_sources:
        raise ValueError('Source subset differs from manifest')
    if set(manifest['roles'].values()) != {a['name'] for a in assets}:
        raise ValueError('Semantic roles and source subset differ')
    result = {}
    for source in [manifest['license'], *assets]:
        data = (INPUT / source['source']).read_bytes()
        if digest(data) != source['sha256']:
            raise ValueError(f"Source hash mismatch: {source['source']}")
        if 'name' in source:
            for stroke in TIERS:
                result[f"stroke-{stroke}/{source['name']}.svg"] = normalize(data, stroke)
    notice = ('Iconoir regular SVG subset, plus the solid star (star-solid.svg)\n'
              f"Source: {manifest['repository']}\nRevision: {manifest['revision']}\n"
              'Derivative changes: stroke widths normalized to 1.25 / 1.0 viewBox units.\n\n')
    custom_notice = ('\nOriginal Alkion category outlines (alkion-*.svg)\n'
                     'Copyright (C) 2026 Animus Studio. SPDX-License-Identifier: AGPL-3.0-only.\n'
                     'These are original Alkion drawings, not Iconoir originals or derivatives.\n'
                     'See the application LICENSE for the complete license text.\n'
                     'Only the upstream subset above is covered by the Iconoir MIT notice.\n')
    result['NOTICE'] = (notice.encode() + (INPUT / manifest['license']['source']).read_bytes()
                        + custom_notice.encode())
    hashes = {name: digest(data) for name, data in sorted(result.items())}
    result['manifest.json'] = (json.dumps(hashes, indent=2) + '\n').encode()
    return result


def generate(check=False):
    result = outputs()
    # The runtime bundle includes only the notice and the two SVG directories;
    # derivative hashes stay with generation inputs outside the asset bundle.
    for name, data in result.items():
        path = INPUT / 'derivatives.json' if name == 'manifest.json' else OUTPUT / name
        if check:
            if not path.is_file() or path.read_bytes() != data:
                raise ValueError(f'Derivative differs: {path.relative_to(APP)}')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    expected = set(result) - {'manifest.json'}
    actual = {str(p.relative_to(OUTPUT)) for p in OUTPUT.rglob('*') if p.is_file()}
    if actual != expected:
        raise ValueError('Runtime subset differs from generated manifest')
    return len(expected) - 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    count = generate(args.check)
    print(f'Iconoir: {count} SVG derivatives verified' if args.check else f'Iconoir: generated {count} SVG derivatives')
