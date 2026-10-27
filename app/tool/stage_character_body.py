#!/usr/bin/env python3
"""Stage the approved private inputs for an explicitly opted-in local APK.

This does not grant publication rights. No source/diagnostic GLB is copied.
All inputs are verified before the first copy; output is always ignored build/.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

FILES = {
    'male': {
        'body.mesh.json': '6829c02247a71db00ae22cc28394abf7b167bf9950b74d2d942491fa53f5dd30',
        'body.mesh.bin': '9d0bd2ac90dedb07de67649eb1bc0048af62d2b6fb4e63b4297c02e4da00d7d5',
        'regions.png': 'bb6927a099bf443105e3012c11ac6ab92f50a2b5b21cbc39658901996c89ded6',
    },
    'female': {
        'body.mesh.json': 'f6cd48d118391eab03e352e95ddc007b64de44beb66b9110b1667cd0f1174969',
        'body.mesh.bin': '3b984e77181e3ecbbf004a3351a6f25e38bac887bc8559e0751ca3f41c8540da',
        'regions.png': '77d018546c236b7125a413c753a0d03d3a2bd348ec209b3849865049fbab7fb7',
    },
}
APP = Path(__file__).resolve().parents[1]
OUTPUT = APP / 'build/private-character-body/assets/body_models'


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def verify(inputs):
    for style, hashes in FILES.items():
        for name, expected in hashes.items():
            path = inputs[style] / name
            if not path.is_file() or path.is_symlink() or digest(path) != expected:
                raise ValueError(f'{style}/{name}: missing, symlinked or not approved bytes')
        manifest = json.loads((inputs[style] / 'body.mesh.json').read_text())
        if manifest.get('sha256') != hashes['body.mesh.bin']:
            raise ValueError(f'{style}: manifest/binary disagreement')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--male-assets', type=Path)
    parser.add_argument('--female-assets', type=Path)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    if args.verify:
        verify({style: OUTPUT / style for style in FILES})
        print('Private body staging: six approved files verified')
        return
    if not args.male_assets or not args.female_assets:
        parser.error('Both explicit private asset directories are required')
    inputs = {'male': args.male_assets.resolve(), 'female': args.female_assets.resolve()}
    if any(path.is_relative_to(APP.parent) for path in inputs.values()):
        parser.error('Private inputs must remain outside the source checkout')
    verify(inputs)
    if OUTPUT.exists():
        verify({style: OUTPUT / style for style in FILES})
        print('Private body staging already matches approved bytes')
        return
    # Reject a redirected output ancestor rather than writing through a symlink.
    for ancestor in [OUTPUT, *OUTPUT.parents]:
        if ancestor == APP:
            break
        if ancestor.is_symlink():
            raise ValueError('Staging output must not contain symlinked directories')
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.body-stage-', dir=OUTPUT.parent) as temp:
        staged = Path(temp) / 'body_models'
        staged.mkdir()
        for style, hashes in FILES.items():
            (staged / style).mkdir()
            for name in hashes:
                shutil.copyfile(inputs[style] / name, staged / style / name)
        verify({style: staged / style for style in FILES})
        (staged / 'staged.json').write_text(json.dumps({'version': 1, 'sha256': FILES}, sort_keys=True) + '\n')
        staged.rename(OUTPUT)
    print('Private body staging complete; opt in with ALKION_PRIVATE_BODY_ASSETS=1')


if __name__ == '__main__':
    main()
