#!/usr/bin/env python3
"""Stage this study and explicit derived assets outside the source checkout."""
import argparse
from pathlib import Path
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--assets', required=True, type=Path)
parser.add_argument('--out', required=True, type=Path)
args = parser.parse_args()
study = Path(__file__).resolve().parents[1]
repo = study.parents[2]
out = args.out.resolve()
if out.is_relative_to(repo) or args.assets.resolve().is_relative_to(repo):
    parser.error('Derived assets and preview must be outside the source checkout')
files = ['index.html', 'study.css', 'study.js', 'renderer.js', 'geometry.js', 'source-geometry.js', 'pose-geometry.js', 'motion.js', 'material.js', 'workload.js']
fonts = ['SpaceMono-Regular.ttf', 'SpaceMono-OFL.txt', 'SpaceGrotesk-Variable.ttf', 'SpaceGrotesk-OFL.txt', 'body_workload_cases.json']
derived = ['body.mesh.json', 'body.mesh.bin', 'regions.png']
for source in [*(study/name for name in files), *(study/'assets'/name for name in fonts), *(args.assets/name for name in derived)]:
    if not source.is_file():
        parser.error(f'Missing required file: {source.name}')
(out/'assets').mkdir(parents=True, exist_ok=True)
for name in files:
    shutil.copyfile(study/name, out/name)
for name in fonts:
    shutil.copyfile(study/'assets'/name, out/'assets'/name)
for name in derived:
    shutil.copyfile(args.assets/name, out/'assets'/name)
print('Private preview staged; source texture and original GLB are not runtime assets.')
