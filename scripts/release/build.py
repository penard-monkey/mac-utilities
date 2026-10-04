#!/usr/bin/python3
"""Build universal macOS release assets without installing anything on this Mac."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
sys.dont_write_bytecode = True
from version_gate import check, repo_slug

IGNORE = shutil.ignore_patterns('.git', '.build', '.swiftpm', '.planning', '__pycache__', '.DS_Store', 'tests', 'Tests')


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def archive(source, destination):
    # Our bundles contain ordinary files/directories, no framework symlinks.
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as output:
        for path in sorted([source] + list(source.rglob('*'))):
            if path.is_symlink():
                raise ValueError('Release archives cannot contain symlinks: ' + str(path))
            output.write(path, str(path.relative_to(source.parent)))


def build(repo, output, scratch, disable_sandbox=False):
    version = check(repo)
    tag = 'v' + version
    slug = repo_slug(repo)
    manifests = []
    for path in sorted(list(repo.glob('*/mac-utility.json')) + list(repo.glob('swiftbar/*/mac-utility.json'))):
        manifest = json.loads(path.read_text())
        # Private/system utilities belong to external sources, never the public catalog.
        if not manifest.get('privileged', False):
            manifests.append((manifest, path.parent))
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Output directory must be empty (avoid shipping stale assets)')
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='package-', dir=str(scratch)) as work:
        stage = Path(work)
        catalog = stage/'Catalog'
        catalog.mkdir()
        assets = {}
        for manifest, source in manifests:
            dest = catalog / source.relative_to(repo)
            shutil.copytree(source, dest, ignore=IGNORE)
            if 'app' in manifest:
                asset = manifest['id'] + '-universal.app.zip'
                assets[manifest['id']] = asset
                metadata = {'schema': 1, 'tag': tag, 'repo': slug, 'asset': asset, 'app': manifest['app'], 'version': manifest['version']}
                metadata.update(manifest.get('release', {}))
                (dest/'release-app.json').write_text(json.dumps(metadata, indent=2)+'\n')
                shutil.copy2(repo/'scripts/release/install.py', dest/'release-install.py')
                hook = dest/'scripts/release-install.sh'
                hook.parent.mkdir(exist_ok=True)
                hook.write_text('#!/bin/bash\nset -euo pipefail\nROOT="$(cd "$(dirname "$0")/.." && pwd)"\nexec /usr/bin/python3 "$ROOT/release-install.py" --stage-app "$ROOT/release-app.json" "$1"\n')
                hook.chmod(0o755)
                manifest = dict(manifest, install={'command': ['scripts/release-install.sh', '{applications}']})
                (dest/'mac-utility.json').write_text(json.dumps(manifest, indent=2)+'\n')
        metadata = {'schema': 1, 'tag': tag, 'version': version, 'repo': slug,
                    'manager': 'utilities-manager-universal.app.zip', 'catalog': 'mac-utilities-catalog.zip',
                    'utilities': assets, 'minimum_macos': '14.0'}
        if (repo/'LICENSE').is_file():
            shutil.copy2(repo/'LICENSE', catalog/'LICENSE')
        (catalog/'release.json').write_text(json.dumps(metadata, indent=2)+'\n')
        (output/'release.json').write_text(json.dumps(metadata, indent=2)+'\n')
        archive(catalog, output/metadata['catalog'])
        apps = [('utilities-manager', repo/'utilities-manager', {'name':'Mac Utilities.app'}, version)]
        apps += [(m['id'], s, m['app'], m['version']) for m, s in manifests if 'app' in m]
        for utility_id, source, app, app_version in apps:
            info = plistlib.loads((source/'Info.plist').read_bytes())
            executable = info['CFBundleExecutable']
            # Explicit triples keep both slices at macOS 14 even with newer SDKs.
            binaries = []
            for arch in ('arm64', 'x86_64'):
                options = ['--package-path', source, '--scratch-path', scratch/utility_id/arch,
                           '-c', 'release', '--triple', arch+'-apple-macosx14.0']
                if disable_sandbox:
                    options += ['--disable-sandbox']
                run('/usr/bin/swift', 'build', *options)
                binary_dir = Path(subprocess.check_output(['/usr/bin/swift', 'build']+[str(a) for a in options]+['--show-bin-path'], text=True).strip())
                binaries.append(binary_dir/executable)
            bundle = stage/app['name']
            macos = bundle/'Contents/MacOS'
            resources = bundle/'Contents/Resources'
            macos.mkdir(parents=True)
            resources.mkdir()
            run('/usr/bin/lipo', '-create', *binaries, '-output', macos/executable)
            info['CFBundleShortVersionString'] = app_version
            info['CFBundleVersion'] = app_version
            (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            if (repo/'LICENSE').is_file():
                shutil.copy2(repo/'LICENSE', resources/'LICENSE')
            if utility_id == 'utilities-manager':
                shutil.copytree(repo/'utilities-manager/backend', resources/'Backend', ignore=IGNORE)
                shutil.copy2(repo/'scripts/release/install.py', resources/'Backend/release.py')
                shutil.copytree(catalog, resources/'Catalog')
                (resources/'release-config.json').write_text(json.dumps({'repo':slug, 'version':version})+'\n')
            if (source/'scripts/make-icon.swift').is_file():
                run('/usr/bin/swift', source/'scripts/make-icon.swift', stage/'AppIcon.iconset')
                run('/usr/bin/iconutil', '-c', 'icns', stage/'AppIcon.iconset', '-o', resources/'AppIcon.icns')
            # Future app resources must be declared/copied here before signing; fail verification if absent.
            archs = subprocess.check_output(['/usr/bin/lipo', '-archs', str(macos/executable)], text=True).split()
            if set(archs) != {'arm64', 'x86_64'}:
                raise ValueError('Expected both macOS architectures: '+str(archs))
            commands = subprocess.check_output(['/usr/bin/otool', '-arch', 'all', '-l', str(macos/executable)], text=True)
            minimums = re.findall(r'^\s*minos ([0-9.]+)$', commands, re.M)
            if minimums != ['14.0', '14.0']:
                raise ValueError('Expected macOS 14 deployment target in both slices: '+str(minimums))
            run('/usr/bin/codesign', '--force', '--sign', '-', bundle)
            run('/usr/bin/codesign', '--verify', '--strict', bundle)
            archive(bundle, output/(metadata['manager'] if utility_id == 'utilities-manager' else assets[utility_id]))
        shutil.copy2(repo/'scripts/release/install.py', output/'release-runtime.py')
        for path in sorted(output.iterdir()):
            checksum = hashlib.sha256(path.read_bytes()).hexdigest()
            (output/(path.name+'.sha256')).write_text(checksum+'  '+path.name+'\n')
        (output/'checksums.txt').write_text(''.join(p.read_text() for p in sorted(output.glob('*.sha256'))))
        changelog = (repo/'CHANGELOG.md').read_text()
        notes = re.search(r'^## \['+re.escape(version)+r'\]\n(.*?)(?=^## \[|\Z)', changelog, re.M|re.S).group(1).strip()
        (output/'notes.md').write_text('Mac Utilities '+tag+'\n\n'+notes+'\n')
    print('Release artifacts: '+str(output))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--scratch', type=Path, required=True)
    parser.add_argument('--disable-sandbox', action='store_true')
    args = parser.parse_args()
    build(args.repo.resolve(), args.output.resolve(), args.scratch.resolve(), args.disable_sandbox)
