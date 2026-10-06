#!/usr/bin/python3
"""Build universal macOS release assets without installing anything on this Mac."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
sys.dont_write_bytecode = True
from version_gate import check, repo_slug

IGNORE = shutil.ignore_patterns('.git', '.build', '.swiftpm', '.planning', '__pycache__', '.DS_Store', 'tests', 'Tests', 'Vendor')
MACHO_MAGIC = {b'\xca\xfe\xba\xbe', b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe'}


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def archive(source, destination):
    # Our bundles contain ordinary files/directories, no framework symlinks.
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as output:
        for path in sorted([source] + list(source.rglob('*'))):
            if path.is_symlink():
                raise ValueError('Release archives cannot contain symlinks: ' + str(path))
            output.write(path, str(path.relative_to(source.parent)))


def minimums(binary):
    """Minimum macOS per slice, from LC_BUILD_VERSION (minos) or the older
    LC_VERSION_MIN_MACOSX (version) that some prebuilt libraries still use."""
    commands = subprocess.check_output(['/usr/bin/otool', '-arch', 'all', '-l', str(binary)], text=True)
    return re.findall(r'^\s*(?:minos|cmd LC_VERSION_MIN_MACOSX\n\s*cmdsize \d+\n\s*version) ([0-9.]+)$', commands, re.M)


def version_tuple(value):
    return tuple(int(part) for part in value.split('.'))


def verify_bundle(bundle, app, version):
    """Every Mach-O is universal and runs on macOS 14; the app and its
    extensions target exactly 14.0; extensions are sandboxed; the whole bundle
    verifies; licenses ship in Resources."""
    info = plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != app['bundle_id'] or info.get('CFBundleShortVersionString') != version:
        raise ValueError('Unexpected identity or version in '+bundle.name)
    if not (bundle/'Contents/Resources/LICENSE').is_file():
        raise ValueError('Missing LICENSE in '+bundle.name)
    extensions = [bundle/'Contents/PlugIns'/name for name in app.get('extensions', [])]
    executables = [bundle/'Contents/MacOS'/info['CFBundleExecutable']]
    for extension in extensions:
        extension_info = plistlib.loads((extension/'Contents/Info.plist').read_bytes())
        executables.append(extension/'Contents/MacOS'/extension_info['CFBundleExecutable'])
        entitlements = subprocess.check_output(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(extension)],
                                               stderr=subprocess.DEVNULL)
        if plistlib.loads(entitlements).get('com.apple.security.app-sandbox') is not True:
            raise ValueError('App extensions must be sandboxed: '+extension.name)
    for path in sorted(bundle.rglob('*')):
        if path.is_symlink():
            raise ValueError('Release bundles cannot contain symlinks: '+str(path))
        if not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) not in MACHO_MAGIC:
                continue
        archs = subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).split()
        if set(archs) != {'arm64', 'x86_64'}:
            raise ValueError('Expected both macOS architectures in '+str(path)+': '+str(archs))
        found = minimums(path)
        if len(found) != 2 or (path in executables and found != ['14.0', '14.0']) or \
                any(version_tuple(v) > (14, 0) for v in found):
            raise ValueError('Expected a macOS 14 deployment target in '+str(path)+': '+str(found))
    for path in executables:
        if minimums(path) != ['14.0', '14.0']:
            raise ValueError('Expected macOS 14 deployment target in both slices: '+str(path))
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', bundle)


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
                metadata.update({k: v for k, v in manifest.get('release', {}).items() if k != 'build'})
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
        manager_info = plistlib.loads((repo/'utilities-manager/Info.plist').read_bytes())
        apps = [('utilities-manager', repo/'utilities-manager', {'name':'Mac Utilities.app', 'bundle_id':manager_info['CFBundleIdentifier']}, version, None)]
        apps += [(m['id'], s, m['app'], m['version'], m.get('release', {}).get('build')) for m, s in manifests if 'app' in m]
        for utility_id, source, app, app_version, build_hook in apps:
            if build_hook:
                # Utilities that SwiftPM cannot build (app extensions) supply a
                # hook that writes the signed universal bundle into the stage.
                hook = source/build_hook
                if PurePosixPath(build_hook).is_absolute() or '..' in PurePosixPath(build_hook).parts or not hook.is_file():
                    raise ValueError('Release build hook must be a file inside its utility: '+str(build_hook))
                run('/bin/bash', hook, '--output', stage, '--version', app_version,
                    '--scratch', scratch/utility_id, '--license', repo/'LICENSE')
                bundle = stage/app['name']
                verify_bundle(bundle, app, app_version)
                archive(bundle, output/assets[utility_id])
                continue
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
            if (source/'Resources/AppIcon.icns').is_file():
                shutil.copy2(source/'Resources/AppIcon.icns', resources/'AppIcon.icns')
            # Future app resources must be declared/copied here before signing; fail verification if absent.
            run('/usr/bin/codesign', '--force', '--sign', '-', bundle)
            verify_bundle(bundle, app, app_version)
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
