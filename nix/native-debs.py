# SPDX-License-Identifier: MIT
"""Compile the shared immutable object graph into native-owned DEBs."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

collection, destination = map(Path, sys.argv[1:3])
architecture = sys.argv[3]
destination.mkdir()
for package in json.loads((collection / 'packages.json').read_text()):
    record = json.loads((collection / package / 'metadata.json').read_text())
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / 'root'
        shutil.copytree(collection / package / 'tree', root, symlinks=True)
        root.chmod(0o755)
        checksums = []
        for entry in sorted(root.rglob('*')):
            if entry.is_file() and not entry.is_symlink():
                with entry.open('rb') as stream:
                    digest = hashlib.file_digest(stream, 'md5').hexdigest()
                checksums.append(digest + '  ' + entry.relative_to(root).as_posix())
        control = root / 'DEBIAN'
        control.mkdir()
        text = (f'Package: {record["name"]}\nVersion: {record["version"]}\nArchitecture: {architecture}\n'
                'Maintainer: nix-impurifiers <root@localhost>\n'
                'Description: Native-owned Nix-built payload\n')
        if record['dependencies']:
            text += 'Depends: ' + ', '.join(name + ' (= 1)' for name in record['dependencies']) + '\n'
        (control / 'control').write_text(text)
        (control / 'md5sums').write_text('\n'.join(checksums) + ('\n' if checksums else ''))
        subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(root),
                        str(destination / f'{record["name"]}_{record["version"]}.deb')], check=True)
