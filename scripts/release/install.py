#!/usr/bin/python3
"""Verified release installation; Python 3.9 standard library and macOS tools only."""
import argparse
import hashlib
import importlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from urllib.parse import urlsplit

sys.dont_write_bytecode = True


class ReleaseError(Exception):
    pass


def tag_version(tag):
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
        raise ReleaseError('Expected a stable vX.Y.Z tag')
    return tag[1:]


def checksums(path):
    result = {}
    for line in path.read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([a-zA-Z0-9][a-zA-Z0-9._-]*)', line)
        if not match or match[2] in result:
            raise ReleaseError('Malformed or duplicate checksum entry')
        result[match[2]] = match[1]
    if not result:
        raise ReleaseError('Empty checksums.txt')
    return result


def copy_quarantine(source, destination):
    attribute = subprocess.run(['/usr/bin/xattr', '-p', 'com.apple.quarantine', str(source)],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if attribute.returncode == 0:
        subprocess.run(['/usr/bin/xattr', '-wr', 'com.apple.quarantine', attribute.stdout.rstrip('\n'), str(destination)], check=True)


def download(url, target):
    subprocess.run(['/usr/bin/curl', '--connect-timeout', '15', '--max-time', '180', '-fsSL', url, '-o', str(target)], check=True)


def release_base(repo):
    base = os.environ.get('MAC_UTILITIES_RELEASE_BASE_URL', 'https://github.com/'+repo).rstrip('/')
    parsed = urlsplit(base)
    if parsed.username or parsed.password or parsed.query or parsed.fragment or not parsed.hostname:
        raise ReleaseError('Invalid release feed URL')
    if parsed.scheme != 'https' and not (parsed.scheme == 'http' and parsed.hostname in ('127.0.0.1', 'localhost', '::1')):
        raise ReleaseError('Release feeds require HTTPS (HTTP loopback is allowed for isolated tests)')
    return base


def latest_tag(repo):
    base = release_base(repo)
    url = subprocess.check_output(['/usr/bin/curl', '--connect-timeout', '15', '--max-time', '60', '-fsSLI',
                                   '-o', '/dev/null', '-w', '%{url_effective}', base+'/releases/latest'], text=True)
    prefix = base+'/releases/tag/'
    if not url.startswith(prefix):
        raise ReleaseError('Could not resolve latest release. Publish a stable release first.')
    tag = url[len(prefix):]
    tag_version(tag)
    return tag


class Feed:
    def __init__(self, repo, tag, work, artifacts=None):
        tag_version(tag)
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
            raise ReleaseError('Invalid repository slug')
        self.base = release_base(repo) + '/releases/download/' + tag
        self.work = Path(work)
        self.artifacts = Path(artifacts).resolve() if artifacts else None
        self.fetch('checksums.txt', verify=False)
        self.sums = checksums(self.work/'checksums.txt')

    def fetch(self, name, verify=True):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name):
            raise ReleaseError('Invalid asset name')
        target = self.work/name
        if self.artifacts:
            source = self.artifacts/name
            if source.is_symlink() or not source.is_file():
                raise ReleaseError('Missing artifact: ' + name)
            shutil.copy2(source, target)
            copy_quarantine(source, target)
        else:
            download(self.base+'/'+name, target)
        if verify and (name not in self.sums or hashlib.sha256(target.read_bytes()).hexdigest() != self.sums[name]):
            raise ReleaseError('Checksum verification failed: '+name)
        return target


def extract(archive, destination):
    """No absolute paths, traversal, special files, or symlinks; preserve modes."""
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    seen = set()
    with zipfile.ZipFile(archive) as source:
        for entry in source.infolist():
            path = PurePosixPath(entry.filename)
            if (path.is_absolute() or '..' in path.parts or '\\' in entry.filename or
                    not path.parts or path.parts in seen):
                raise ReleaseError('Unsafe/duplicate archive path: '+entry.filename)
            seen.add(path.parts)
            mode = entry.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFDIR, stat.S_IFREG):
                raise ReleaseError('Archive contains a symlink or special file: '+entry.filename)
            target = destination.joinpath(*path.parts)
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.open(entry) as stream, target.open('xb') as output:
                    shutil.copyfileobj(stream, output)
            target.chmod((mode & 0o777) or (0o755 if entry.is_dir() else 0o644))
    copy_quarantine(archive, destination)


def validate_app(bundle, app, version=None):
    info = plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
    if version is not None and info.get('CFBundleShortVersionString') != version:
        raise ReleaseError('App bundle version mismatch')
    if info.get('CFBundleIdentifier') != app['bundle_id']:
        raise ReleaseError('App bundle identity mismatch')
    binary = info.get('CFBundleExecutable', '')
    if Path(binary).name != binary or not binary or not os.access(str(bundle/'Contents/MacOS'/binary), os.X_OK):
        raise ReleaseError('Missing executable in app bundle')


def stage_app(metadata_path, applications):
    metadata = json.loads(Path(metadata_path).read_text())
    tag_version(metadata['tag'])
    home = Path.home()
    cache = home/'Library/Application Support/mac-utilities/releases'/metadata['tag']/'Assets'
    with tempfile.TemporaryDirectory(prefix='mac-utility-app-') as work:
        feed = Feed(metadata['repo'], metadata['tag'], work, cache if (cache/'checksums.txt').exists() else None)
        asset = feed.fetch(metadata['asset'])
        extracted = Path(work)/'extracted'
        extract(asset, extracted)
        bundle = extracted/metadata['app']['name']
        validate_app(bundle, metadata['app'], metadata.get('version'))
        if os.environ.get('MAC_UTILITIES_STRIP_QUARANTINE') == '1':
            subprocess.run(['/usr/bin/xattr', '-dr', 'com.apple.quarantine', str(bundle)], check=False)
        target = Path(applications)/bundle.name
        if target.exists() or target.is_symlink():
            raise ReleaseError('Staged app destination is occupied')
        subprocess.run(['/usr/bin/ditto', str(bundle), str(target)], check=True)
        if metadata.get('engine_install') and os.environ.get('MAC_UTILITIES_NO_SYSTEM_EFFECTS') != '1':
            if metadata.get('engine_arch') and platform.machine() != metadata['engine_arch']:
                raise ReleaseError('The local transcription engine requires Apple Silicon')
            relative = PurePosixPath(metadata['engine_install'])
            if relative.is_absolute() or '..' in relative.parts:
                raise ReleaseError('Engine installer path must stay in its utility')
            hook = Path(metadata_path).parent.joinpath(*relative.parts)
            subprocess.run([str(hook)], check=True)


def backend_path(home):
    candidates = [Path(__file__).parent, home/'Applications/Mac Utilities.app/Contents/Resources/Backend',
                  Path(__file__).resolve().parents[2]/'utilities-manager/backend']
    for candidate in candidates:
        if (candidate/'lifecycle.py').is_file():
            return candidate
    raise ReleaseError('Install Mac Utilities before checking installed utility updates')


def newer(candidate, installed):
    """True only when candidate is strictly newer than installed (None = not installed)."""
    if not installed:
        return True
    if not candidate:
        return False
    def parts(value): return tuple(int(p) for p in value.lstrip('v').split('.'))
    return parts(candidate) > parts(installed)


def manager_state(home, meta, current=None):
    """(installed manager version, whether the manager needs updating)."""
    if not current:
        info = home/'Applications/Mac Utilities.app/Contents/Info.plist'
        current = plistlib.loads(info.read_bytes()).get('CFBundleShortVersionString') if info.exists() else None
    receipt_path = home/'Library/Application Support/mac-utilities/state/manager-app.json'
    receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
    migration = current == meta['version'] and not receipt.get('release')
    return current, newer(meta['version'], current) or migration


def check_updates(args):
    home = Path(args.home).expanduser().resolve()
    with tempfile.TemporaryDirectory(prefix='mac-utilities-check-') as work:
        work = Path(work)
        feed = Feed(args.repo, args.tag, work, args.artifacts)
        meta = json.loads(feed.fetch('release.json').read_text())
        if meta.get('tag') != args.tag or meta.get('repo') != args.repo or meta.get('version') != tag_version(args.tag):
            raise ReleaseError('Release metadata mismatch')
        extract(feed.fetch(meta['catalog']), work/'catalog')
        sys.path.insert(0, str(backend_path(home)))
        lifecycle = importlib.import_module('lifecycle')
        manager = lifecycle.Manager(work/'catalog/Catalog', home, system_effects=False)
        current, manager_update = manager_state(home, meta, args.current_version)
        with manager.lock():
            entries = manager.catalog()
        return {'current': current, 'latest': args.tag, 'manager_update': manager_update,
                'utilities': [{'id': e['id'], 'name': e['name'], 'current': e['version'],
                               'latest': e['available_version'], 'available': e['available'],
                               'update_available': e['update_available'], 'healthy': e['healthy'],
                               'external': e['source'] != str(manager.repo), 'issue': e['issue']}
                              for e in entries if e['installed']]}


def local_action(args):
    """Folder updates and removal work even when the public feed is offline."""
    if args.action not in ('uninstall', 'update') or (args.action == 'update' and (args.all or not args.id or args.id == 'manager')):
        return None
    home = Path(args.home).expanduser().resolve()
    try:
        directory = backend_path(home)
    except ReleaseError:
        return None  # Legacy standalone plugin installs have no manager backend yet.
    if args.action == 'uninstall' and args.id == 'manager' and not (directory/'package_app.py').is_file():
        return None
    sys.path.insert(0, str(directory))
    lifecycle = importlib.import_module('lifecycle')
    settings = home/'.config/mac-utilities/utilities-manager.json'
    saved = json.loads(settings.read_text()) if settings.exists() else {}
    source = saved.get('source', str(home/'Applications/Mac Utilities.app/Contents/Resources/Catalog'))
    manager = lifecycle.Manager(source, home, system_effects=not args.no_system_effects)
    with manager.lock():
        if args.action == 'uninstall':
            if not args.id:
                raise ReleaseError('Select a utility id or manager to uninstall')
            if args.id == 'manager':
                package = importlib.import_module('package_app')
                package.uninstall(manager, home/'Applications/Mac Utilities.app')
                return {'message':'Removed manager; settings and installed utilities retained.'}
            return manager.uninstall(args.id)
        sources = manager.manifests()
        entry = sources.get(args.id)
        source_root = manager.catalog_source(entry[1]) if entry and hasattr(manager, 'catalog_source') else manager.repo
        if entry and source_root != manager.repo:
            if not manager.receipt(args.id):
                raise ReleaseError('Install the utility before updating it')
            return manager.install(args.id)
    return None


def install(args):
    home = Path(args.home).expanduser().resolve()
    if home != Path.home().resolve() and not args.no_system_effects:
        raise ReleaseError('Alternate homes require --no-system-effects')
    root = home/'Library/Application Support/mac-utilities'
    apps = home/'Applications'
    tag_version(args.tag)
    if args.strip_quarantine:
        os.environ['MAC_UTILITIES_STRIP_QUARANTINE'] = '1'
    messages = []
    with tempfile.TemporaryDirectory(prefix='mac-utilities-release-') as work:
        work = Path(work)
        feed = Feed(args.repo, args.tag, work, args.artifacts)
        meta = json.loads(feed.fetch('release.json').read_text())
        if meta.get('schema') != 1 or meta.get('tag') != args.tag or meta.get('version') != tag_version(args.tag) or meta.get('repo') != args.repo:
            raise ReleaseError('Release metadata mismatch')
        # Verify both assets before any installation change.
        manager_zip = feed.fetch(meta['manager'])
        catalog_zip = feed.fetch(meta['catalog'])
        extract(manager_zip, work/'app')
        extract(catalog_zip, work/'catalog')
        bundle = work/'app/Mac Utilities.app'
        validate_app(bundle, {'bundle_id':'com.macutilities.manager'}, meta['version'])
        backend = bundle/'Contents/Resources/Backend'
        if not (backend/'lifecycle.py').is_file() or not (backend/'package_app.py').is_file():
            raise ReleaseError('Release manager backend is incomplete')
        catalog = work/'catalog/Catalog'
        if json.loads((catalog/'release.json').read_text()) != meta:
            raise ReleaseError('Catalog metadata mismatch')
        sys.path.insert(0, str(backend))
        lifecycle = importlib.import_module('lifecycle')
        package = importlib.import_module('package_app')
        manager = lifecycle.Manager(catalog, home, system_effects=not args.no_system_effects)
        selected = []
        # Install always lays down the manager; update touches it only when asked or newer.
        update_manager = args.action == 'install' or args.id == 'manager'
        if args.action == 'install':
            selected = [v for v in os.environ.get('MAC_UTILITIES_INSTALL', '').split(',') if v]
            if args.id:
                selected = [args.id]
            elif 'MAC_UTILITIES_INSTALL' not in os.environ and not args.no_system_effects:
                try:
                    with open('/dev/tty', 'r+') as tty:
                        tty.write('Optional utilities (comma-separated IDs, Return for manager + Tools): ')
                        tty.flush()
                        selected = [v.strip() for v in tty.readline().strip().split(',') if v.strip()]
                except OSError:
                    pass
            selected = list(dict.fromkeys(['tools'] + selected))
        with manager.lock():
            if args.action != 'uninstall':
                # Immutable versioned catalog stays independent of the transient download.
                stable_catalog = root/'releases'/args.tag/'Catalog'
                if stable_catalog.exists():
                    if stable_catalog.is_symlink() or lifecycle.digest(stable_catalog) != lifecycle.digest(catalog):
                        raise ReleaseError('Release catalog was modified; leaving it alone: '+str(stable_catalog))
                else:
                    stable_catalog.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copytree(catalog, stable_catalog)
                manager.repo = stable_catalog.resolve()
            available = manager.manifests()
            if args.action == 'uninstall':
                if not args.id:
                    raise ReleaseError('Select a utility id or manager to uninstall')
                if args.id == 'manager':
                    package.uninstall(manager, apps/'Mac Utilities.app')
                else:
                    manager.uninstall(args.id)
                return {'message': 'Removed managed files; settings and keys retained.'}
            if args.action == 'update':
                if args.all:
                    update_manager = manager_state(home, meta)[1]
                    selected = [entry['id'] for entry in manager.catalog() if entry['installed'] and entry['update_available']]
                elif args.id and args.id != 'manager':
                    if not manager.receipt(args.id):
                        raise ReleaseError('Install the utility before updating it')
                    selected = [args.id]
                elif args.id != 'manager':
                    raise ReleaseError('Update requires an id or --all')
            for utility_id in selected:
                if utility_id not in available:
                    raise ReleaseError('Utility is absent from release catalog: '+utility_id)
                old = manager.receipt(utility_id)
                if old:
                    manager.verify(old)
            # A local proof stays independent of the original artifacts directory.
            # Cache immutable verified copies; app hooks can use them without a network.
            cache = root/'releases'/args.tag/'Assets'
            if args.artifacts:
                cache.mkdir(parents=True, exist_ok=True)
                for name in meta['utilities'].values():
                    source = feed.fetch(name)
                    shutil.copy2(source, cache/name)
                    copy_quarantine(source, cache/name)
                shutil.copy2(work/'checksums.txt', cache/'checksums.txt')
            if update_manager:
                apps.mkdir(parents=True, exist_ok=True)
                with tempfile.TemporaryDirectory(prefix='.mac-utilities-', dir=str(apps)) as appstage:
                    staged = Path(appstage)/bundle.name
                    subprocess.run(['/usr/bin/ditto', str(bundle), str(staged)], check=True)
                    if args.strip_quarantine:
                        subprocess.run(['/usr/bin/xattr', '-dr', 'com.apple.quarantine', str(staged)], check=False)
                    package.publish(manager, staged, apps/bundle.name)
                    manager_receipt = root/'state/manager-app.json'
                    record = json.loads(manager_receipt.read_text())
                    record['release'] = {'repo': args.repo, 'tag': args.tag}
                    lifecycle.atomic_json(manager_receipt, record)
            for utility_id in selected:
                result = manager.install(utility_id)
                receipt = manager.receipt(utility_id)
                if manager.catalog_source(available[utility_id][1]) == manager.repo:
                    receipt['release'] = {'repo': args.repo, 'tag': args.tag}
                else:
                    receipt.pop('release', None)
                lifecycle.atomic_json(manager.receipts/(utility_id+'.json'), receipt)
                messages.append(result['message'])
            settings = manager.config/'utilities-manager.json'
            saved = json.loads(settings.read_text()) if settings.exists() else {}
            saved['source'] = str(manager.repo)
            lifecycle.atomic_json(settings, saved)
            lifecycle.atomic_json(root/'state/release.json', {'schema':1, 'repo':args.repo, 'tag':args.tag,
                                'catalog':str(manager.repo)})
            messages.append('Release '+args.tag+' installed. Restart running apps to use the new version.')
            return {'message': '\n'.join(messages), 'relaunch':update_manager}


def main():
    # Catalog hook entry point uses HOME provided by the lifecycle backend.
    if len(sys.argv) == 4 and sys.argv[1] == '--stage-app':
        stage_app(sys.argv[2], sys.argv[3])
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--tag')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--current-version')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--artifacts')
    parser.add_argument('--home', default=str(Path.home()))
    parser.add_argument('--no-system-effects', action='store_true')
    parser.add_argument('--strip-quarantine', action='store_true')
    parser.add_argument('action', choices=('install', 'update', 'uninstall'), default='install', nargs='?')
    parser.add_argument('id', nargs='?')
    parser.add_argument('--all', action='store_true')
    args = parser.parse_args()
    home = Path(args.home).expanduser().resolve()
    if home != Path.home().resolve() and not args.no_system_effects:
        raise ReleaseError('Alternate homes require --no-system-effects')
    result = None if args.check else local_action(args)
    if result is not None:
        print(json.dumps(result) if args.json else result['message'])
        return
    # A folder probe may have imported an older installed backend. Release
    # installs must use the checksum-verified backend from the selected release.
    sys.modules.pop('lifecycle', None)
    sys.modules.pop('package_app', None)
    if not args.tag:
        args.tag = json.loads((Path(args.artifacts)/'release.json').read_text())['tag'] if args.artifacts else latest_tag(args.repo)
    result = check_updates(args) if args.check else install(args)
    print(json.dumps(result) if args.json or args.check else result['message'])


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        if '--json' in sys.argv or '--check' in sys.argv:
            print(json.dumps({'error':str(error)}))
        else:
            print('ERROR: '+str(error), file=sys.stderr)
        sys.exit(1)
