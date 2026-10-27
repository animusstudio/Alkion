import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('stager', Path(__file__).with_name('stage_character_body.py'))
stager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stager)


class StagerTest(unittest.TestCase):
    def test_rejects_tamper_and_symlink_before_copy(self):
        original = stager.FILES
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binary = b'synthetic mesh only'
                digest = hashlib.sha256(binary).hexdigest()
                values = {'body.mesh.bin': binary, 'body.mesh.json': json.dumps({'sha256': digest}).encode(), 'regions.png': b'synthetic mask only'}
                for name, value in values.items():
                    (root / name).write_bytes(value)
                stager.FILES = {'male': {name: hashlib.sha256(value).hexdigest() for name, value in values.items()}}
                stager.verify({'male': root})
                (root / 'body.mesh.bin').write_bytes(b'changed')
                with self.assertRaises(ValueError):
                    stager.verify({'male': root})
                (root / 'body.mesh.bin').unlink()
                (root / 'target').write_bytes(binary)
                (root / 'body.mesh.bin').symlink_to(root / 'target')
                with self.assertRaises(ValueError):
                    stager.verify({'male': root})
        finally:
            stager.FILES = original


if __name__ == '__main__':
    unittest.main()
