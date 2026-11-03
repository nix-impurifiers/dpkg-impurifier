# SPDX-License-Identifier: MIT
"""Package each immutable store object once; dpkg owns its reference graph."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

registration, spec_file, destination = map(Path, sys.argv[1:])
spec = json.loads(spec_file.read_text())
destination.mkdir()
lines = iter(registration.read_text().splitlines())
graph = {}
for path in lines:
    _hash, _size, _deriver, count = (next(lines) for _ in range(4))
    graph[path] = [next(lines) for _ in range(int(count))]


def identity(path):
    return 'nix-store-' + Path(path).name.split('-', 1)[0]


def emit(name, version, dependencies, populate, description):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        populate(root)
        checksums = []
        for entry in sorted(root.rglob('*')):
            if entry.is_file() and not entry.is_symlink():
                with entry.open('rb') as stream:
                    digest = hashlib.file_digest(stream, 'md5').hexdigest()
                checksums.append(digest + '  ' + entry.relative_to(root).as_posix())
        control = root / 'DEBIAN'
        control.mkdir()
        text = (f'Package: {name}\nVersion: {version}\nArchitecture: {spec["architecture"]}\n'
                'Maintainer: nix-impurifiers <root@localhost>\n'
                f'Description: {description}\n')
        if dependencies:
            text += 'Depends: ' + ', '.join(dependencies) + '\n'
        (control / 'control').write_text(text)
        (control / 'md5sums').write_text('\n'.join(checksums) + ('\n' if checksums else ''))
        subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(root),
                        str(destination / f'{name}_{version}.deb')], check=True)


for path, references in sorted(graph.items()):
    def populate(root, path=path):
        target = root / path.lstrip('/')
        target.parent.mkdir(parents=True, exist_ok=True)
        if Path(path).is_symlink():
            target.symlink_to(Path(path).readlink())
        elif Path(path).is_dir():
            shutil.copytree(path, target, symlinks=True)
        else:
            shutil.copy2(path, target)
    emit(identity(path), '1', [identity(ref) + ' (= 1)' for ref in references if ref != path],
         populate, 'Native-owned immutable Nix store object')


def application(root):
    for command in spec['programs']:
        if not (Path(spec['installable']) / 'bin' / command).is_file():
            raise ValueError('missing application command: ' + command)
        target = root / 'usr/bin' / command
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(spec['installable'] + '/bin/' + command)


emit(spec['name'], spec['version'], [identity(spec['installable']) + ' (= 1)'],
     application, 'Nix-built application with native-owned closure')
