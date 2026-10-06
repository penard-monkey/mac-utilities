import hashlib
import contextlib
import http.server
import threading
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_install', ROOT/'scripts/release/install.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
spec = importlib.util.spec_from_file_location('release_gate', ROOT/'scripts/release/version_gate.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.home = self.base/'home with spaces'
        self.home.mkdir()
        self.assets = self.base/'assets'
        self.assets.mkdir()
        self.support = self.home/'Library/Application Support/mac-utilities'
        self.fixture('v1.0.0')

    def tearDown(self):
        self.temp.cleanup()

    def zip(self, source, name):
        with zipfile.ZipFile(self.assets/name, 'w') as archive:
            for path in sorted([source]+list(source.rglob('*'))):
                archive.write(path, str(path.relative_to(source.parent)))

    def sums(self):
        lines = []
        for path in sorted(self.assets.iterdir()):
            if path.name != 'checksums.txt':
                lines.append(hashlib.sha256(path.read_bytes()).hexdigest()+'  '+path.name+'\n')
        (self.assets/'checksums.txt').write_text(''.join(lines))

    def app(self, name, bundle_id, executable, parent, version='1.0.0'):
        app = parent/name
        (app/'Contents/MacOS').mkdir(parents=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bundle_id, 'CFBundleExecutable':executable, 'CFBundleShortVersionString':version}))
        binary = app/'Contents/MacOS'/executable
        binary.write_text('#!/bin/bash\nexit 0\n')
        binary.chmod(0o755)
        return app

    def fixture(self, tag):
        stage = self.base/tag
        stage.mkdir()
        meta = {'schema':1, 'repo':'penard-monkey/mac-utilities', 'tag':tag, 'version':tag[1:],
                'manager':'utilities-manager-universal.app.zip', 'catalog':'mac-utilities-catalog.zip',
                'utilities':{'git-settings':'git-settings-universal.app.zip',
                             'video-preview':'video-preview-universal.app.zip'}, 'minimum_macos':'14.0'}
        (self.assets/'release.json').write_text(json.dumps(meta))
        shutil.copy2(ROOT/'scripts/release/install.py', self.assets/'release-runtime.py')
        catalog = stage/'Catalog'
        for utility_id in ('tools', 'memory'):
            shutil.copytree(ROOT/'swiftbar'/utility_id, catalog/'swiftbar'/utility_id, ignore=shutil.ignore_patterns('__pycache__', 'tests'))
        manifests = {}
        for utility_id in meta['utilities']:
            app_source = catalog/utility_id
            (app_source/'scripts').mkdir(parents=True)
            manifest = json.loads((ROOT/utility_id/'mac-utility.json').read_text())
            manifest['install'] = {'command':['scripts/release-install.sh', '{applications}']}
            (app_source/'mac-utility.json').write_text(json.dumps(manifest))
            (app_source/'release-app.json').write_text(json.dumps({'schema':1, 'repo':meta['repo'], 'tag':tag, 'asset':meta['utilities'][utility_id], 'app':manifest['app'], 'version':manifest['version']}))
            shutil.copy2(ROOT/'scripts/release/install.py', app_source/'release-install.py')
            hook = app_source/'scripts/release-install.sh'
            hook.write_text('#!/bin/bash\nset -eu\nROOT="$(cd "$(dirname "$0")/.." && pwd)"\nexec /usr/bin/python3 "$ROOT/release-install.py" --stage-app "$ROOT/release-app.json" "$1"\n')
            hook.chmod(0o755)
            manifests[utility_id] = manifest
        (catalog/'release.json').write_text(json.dumps(meta))
        self.zip(catalog, meta['catalog'])
        app = self.app('Mac Utilities.app', 'com.macutilities.manager', 'MacUtilities', stage)
        info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        info['CFBundleShortVersionString'] = tag[1:]
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        backend = app/'Contents/Resources/Backend'
        shutil.copytree(ROOT/'utilities-manager/backend', backend, ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copy2(ROOT/'scripts/release/install.py', backend/'release.py')
        (app/'Contents/Resources/release-config.json').write_text(json.dumps({'repo':meta['repo'],'version':meta['version']}))
        shutil.copytree(catalog, app/'Contents/Resources/Catalog')
        self.zip(app, meta['manager'])
        for utility_id, executable in (('git-settings', 'GitSettings'), ('video-preview', 'Video Preview')):
            manifest = manifests[utility_id]
            utility_app = self.app(manifest['app']['name'], manifest['app']['bundle_id'], executable, stage, version=manifest['version'])
            for name in manifest['app'].get('extensions', []):
                extension = self.app(name, manifest['app']['bundle_id']+'.quicklook', 'Extension',
                                     utility_app/'Contents/PlugIns', version=manifest['version'])
                (extension/'Contents/Frameworks').mkdir()
                (extension/'Contents/Frameworks/VLCKit.dylib').write_bytes(b'dylib')
            self.zip(utility_app, meta['utilities'][utility_id])
        self.sums()

    def cli(self, *args, selected='memory,git-settings', success=True):
        result = subprocess.run(['/bin/bash', str(ROOT/'install.sh'), '--artifacts', str(self.assets),
                                 '--home', str(self.home), '--no-system-effects']+list(args),
                                env=dict(os.environ, MAC_UTILITIES_INSTALL=selected), text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode == 0, success, result.stdout)
        return result.stdout

    def test_install_update_uninstall_retains_settings_keys_and_hidden_menu(self):
        for relative in ('.ssh/id_test', '.gitconfig', '.config/mac-utilities/memory.json', '.cache/mac-utilities/memory.json'):
            path = self.home/relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('retain '+relative)
        self.cli()
        self.assertTrue((self.home/'Applications/Git & SSH.app').is_dir())
        record = json.loads((self.support/'state/receipts/git-settings.json').read_text())
        self.assertEqual(record['release']['tag'], 'v1.0.0')
        backend = ROOT/'utilities-manager/backend/lifecycle.py'
        subprocess.run(['/usr/bin/python3', str(backend), '--repo', str(self.base/'v1.0.0/Catalog'), '--home', str(self.home), '--no-system-effects', 'menu', 'memory', 'hide'], check=True, stdout=subprocess.DEVNULL)
        self.fixture('v1.0.1')
        self.cli('update', '--all')
        self.assertFalse(json.loads((self.support/'state/receipts/memory.json').read_text())['visible'])
        self.assertEqual(json.loads((self.support/'state/receipts/git-settings.json').read_text())['release']['tag'], 'v1.0.1')
        self.cli('uninstall', 'git-settings')
        self.cli('uninstall', 'manager')
        self.assertFalse((self.home/'Applications/Git & SSH.app').exists())
        self.assertFalse((self.home/'Applications/Mac Utilities.app').exists())
        for relative in ('.ssh/id_test', '.gitconfig', '.config/mac-utilities/memory.json', '.cache/mac-utilities/memory.json'):
            self.assertEqual((self.home/relative).read_text(), 'retain '+relative)

    def test_bad_checksums_never_install_or_replace(self):
        self.cli()
        receipt = (self.support/'state/manager-app.json').read_bytes()
        (self.assets/'utilities-manager-universal.app.zip').write_bytes(b'corrupt')
        self.assertIn('Checksum', self.cli('update', 'manager', success=False))
        self.assertEqual((self.support/'state/manager-app.json').read_bytes(), receipt)
        (self.assets/'release-runtime.py').write_text('raise Exception("must never execute")')
        self.assertIn('Runtime checksum', self.cli(success=False))
        self.assertEqual((self.support/'state/manager-app.json').read_bytes(), receipt)

    def test_missing_duplicate_and_malformed_checksums_fail_closed(self):
        original = (self.assets/'checksums.txt').read_text()
        line = next(line for line in original.splitlines() if line.endswith('  release-runtime.py'))
        for value in ('', original+line+'\n', original.replace(line, 'bad  release-runtime.py')):
            (self.assets/'checksums.txt').write_text(value)
            self.cli(success=False)
            self.assertFalse((self.home/'Applications').exists())

    def test_foreign_or_modified_manager_is_retained(self):
        app = self.home/'Applications/Mac Utilities.app'
        app.mkdir(parents=True)
        (app/'keep').write_text('foreign')
        self.cli(success=False)
        self.assertEqual((app/'keep').read_text(), 'foreign')
        shutil.rmtree(app)
        self.cli()
        (app/'keep').write_text('modified')
        self.cli('update', 'manager', success=False)
        self.assertEqual((app/'keep').read_text(), 'modified')

    def test_catalog_installs_apps_without_original_artifacts_or_checkout(self):
        self.cli(selected='')
        shutil.rmtree(self.assets)
        app = self.home/'Applications/Mac Utilities.app'
        result = subprocess.run(['/usr/bin/python3', str(app/'Contents/Resources/Backend/lifecycle.py'),
                                 '--repo', str(app/'Contents/Resources/Catalog'), '--home', str(self.home),
                                 '--no-system-effects', 'install', 'git-settings'], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.home/'Applications/Git & SSH.app').exists())

    def test_video_preview_installs_with_its_extension_and_uninstalls(self):
        self.cli(selected='video-preview')
        app = self.home/'Applications/Video Preview.app'
        appex = app/'Contents/PlugIns/VideoPreviewQuickLook.appex'
        self.assertTrue((appex/'Contents/Frameworks/VLCKit.dylib').is_file())
        receipt = json.loads((self.support/'state/receipts/video-preview.json').read_text())
        self.assertEqual(receipt['manifest']['app']['extensions'], ['VideoPreviewQuickLook.appex'])
        self.cli('update', 'video-preview')
        self.cli('uninstall', 'video-preview')
        self.assertFalse(app.exists())

    def test_checkout_receipts_migrate_in_place_without_uninstall(self):
        # Use an actual checkout-built lifecycle receipt, then update from release.
        subprocess.run(['/usr/bin/python3', str(ROOT/'utilities-manager/backend/lifecycle.py'),
                        '--repo', str(ROOT), '--home', str(self.home), '--no-system-effects', 'install', 'memory'], check=True, stdout=subprocess.DEVNULL)
        old = json.loads((self.support/'state/receipts/memory.json').read_text())
        self.assertNotIn('release', old)
        self.cli('update', 'memory')
        new = json.loads((self.support/'state/receipts/memory.json').read_text())
        self.assertEqual(old['payload'], new['payload'])
        self.assertEqual(new['release']['tag'], 'v1.0.0')

    def test_alternate_home_requires_effects_suppression(self):
        result = subprocess.run(['/usr/bin/python3', str(ROOT/'scripts/release/install.py'), '--repo', 'penard-monkey/mac-utilities', '--tag', 'v1.0.0', '--home', str(self.home)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Alternate homes', result.stdout)
        self.assertFalse(self.support.exists())

    def test_zip_traversal_symlink_duplicate_and_special_file_are_refused(self):
        for index, (name, mode) in enumerate((('../escape', stat.S_IFREG), ('/absolute', stat.S_IFREG), ('link', stat.S_IFLNK), ('device', stat.S_IFCHR), ('back\\slash', stat.S_IFREG))):
            path = self.base/('unsafe'+str(index)+'.zip')
            with zipfile.ZipFile(path, 'w') as archive:
                entry = zipfile.ZipInfo(name)
                entry.external_attr = (mode|0o755) << 16
                archive.writestr(entry, 'payload')
            with self.assertRaises(release.ReleaseError): release.extract(path, self.base/('out'+str(index)))
        self.assertFalse((self.base/'escape').exists())

    def test_quarantine_is_preserved_unless_explicitly_requested(self):
        archive = self.assets/'utilities-manager-universal.app.zip'
        value = '0081;00000000;release-test;'
        subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.quarantine', value, str(archive)], check=True)
        self.cli()
        installed = self.home/'Applications/Mac Utilities.app'
        self.assertEqual(subprocess.check_output(['/usr/bin/xattr', '-p', 'com.apple.quarantine', str(installed)], text=True).strip(), value)
        self.cli('--strip-quarantine', 'update', 'manager')
        self.assertNotEqual(subprocess.run(['/usr/bin/xattr', '-p', 'com.apple.quarantine', str(installed)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode, 0)

    def runtime(self, *args, env=None, success=True):
        result = subprocess.run(['/usr/bin/python3', str(ROOT/'scripts/release/install.py'), '--repo',
                                 'penard-monkey/mac-utilities', '--home', str(self.home), '--no-system-effects', '--json']+list(args),
                                env=env or dict(os.environ, MAC_UTILITIES_INSTALL=''), text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode == 0, success, result.stdout)
        return json.loads(result.stdout)

    @contextlib.contextmanager
    def feed(self):
        assets = self.assets
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_HEAD(self):
                if self.path == '/releases/latest':
                    self.send_response(302)
                    self.send_header('Location', '/releases/tag/'+json.loads((assets/'release.json').read_text())['tag'])
                    self.end_headers()
                elif self.path.startswith('/releases/tag/'):
                    self.send_response(200)
                    self.end_headers()
                else:
                    self.send_error(404)
            def do_GET(self):
                prefix = '/releases/download/'+json.loads((assets/'release.json').read_text())['tag']+'/'
                if not self.path.startswith(prefix):
                    self.send_error(404)
                    return
                name = self.path[len(prefix):]
                if '/' in name or not (assets/name).is_file():
                    self.send_error(404)
                    return
                payload = (assets/name).read_bytes()
                self.send_response(200)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield dict(os.environ, MAC_UTILITIES_INSTALL='', MAC_UTILITIES_RELEASE_BASE_URL='http://127.0.0.1:'+str(server.server_port))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_fake_latest_redirect_check_and_manager_update(self):
        self.cli()
        self.fixture('v1.0.1')
        with self.feed() as env:
            status = self.runtime('--check', env=env)
            self.assertEqual(status['current'], '1.0.0')
            self.assertEqual(status['latest'], 'v1.0.1')
            self.assertTrue(status['manager_update'])
            result = self.runtime('update', 'manager', env=env)
            self.assertTrue(result['relaunch'])
        record = json.loads((self.support/'state/manager-app.json').read_text())
        self.assertEqual(record['release']['tag'], 'v1.0.1')
        settings = json.loads((self.home/'.config/mac-utilities/utilities-manager.json').read_text())
        self.assertEqual(settings['source'], str(self.support/'releases/v1.0.1/Catalog'))
        self.assertTrue(Path(settings['source']).is_dir())

    def test_external_sources_keep_updating_from_their_folder(self):
        self.cli(selected='')
        external = self.base/'private-source'
        external.mkdir()
        manifest = {'schema':1, 'id':'private-tool', 'name':'Private tool', 'version':'1.0.0', 'description':'Fixture',
                    'presentation':'plugin', 'plugin':{'path':'private.5s.py'}, 'privileged':False}
        (external/'mac-utility.json').write_text(json.dumps(manifest))
        plugin = external/'private.5s.py'
        plugin.write_text('#!/usr/bin/python3\nprint("first")\n')
        plugin.chmod(0o755)
        config = self.home/'.config/mac-utilities/sources.json'
        config.write_text(json.dumps([str(external)]))
        # Install through the external source, then change its folder and update all.
        subprocess.run(['/usr/bin/python3', str(ROOT/'utilities-manager/backend/lifecycle.py'), '--repo', str(self.base/'v1.0.0/Catalog'),
                        '--home', str(self.home), '--no-system-effects', 'install', 'private-tool'], check=True, stdout=subprocess.DEVNULL)
        plugin.write_text('#!/usr/bin/python3\nprint("second")\n')
        self.cli('update', '--all')
        record = json.loads((self.support/'state/receipts/private-tool.json').read_text())
        self.assertEqual(record['source'], str(external))
        self.assertNotIn('release', record)
        self.assertIn('second', (self.support/'payloads/private-tool/private.5s.py').read_text())
        status = self.runtime('--artifacts', str(self.assets), '--check')
        self.assertTrue(next(e for e in status['utilities'] if e['id']=='private-tool')['external'])
        self.assertEqual(json.loads(config.read_text()), [str(external)])

    def test_system_bash_handles_empty_bootstrap_arguments_and_pin(self):
        environment = dict(os.environ, HOME=str(self.home), MAC_UTILITIES_INSTALL_VERSION='invalid')
        result = subprocess.run(['/bin/bash', str(ROOT/'install.sh')], env=environment,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Expected a stable vX.Y.Z release tag', result.stdout)
        self.assertNotIn('unbound variable', result.stdout)
        self.cli()
        environment.pop('MAC_UTILITIES_INSTALL_VERSION')
        result = subprocess.run(['/bin/bash', str(ROOT/'install.sh'), '--home', str(self.home),
                                 '--no-system-effects', 'uninstall', 'memory'], env=environment,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.support/'state/receipts/memory.json').exists())

    def test_tag_and_script_version_gate(self):
        version = (ROOT/'VERSION').read_text().strip()
        self.assertEqual(gate.check(ROOT), version)
        with self.assertRaises(ValueError): gate.check(ROOT, 'v99.0.0')
        gate_repo = self.base/'version-gate'
        gate_repo.mkdir()
        for name in ('VERSION', 'install.sh', 'CHANGELOG.md'):
            shutil.copy2(ROOT/name, gate_repo/name)
        with self.assertRaisesRegex(ValueError, 'LICENSE'): gate.check(gate_repo, 'v'+version)
        (gate_repo/'LICENSE').write_text('Test fixture license only')
        self.assertEqual(gate.check(gate_repo, 'v'+version), version)
        with self.assertRaises(ValueError): gate.check(ROOT, repository='different/repository')
        for tag in ('v1.0', 'v1.0.0/../../bad', 'v1.0.0-rc1'):
            with self.assertRaises(release.ReleaseError): release.tag_version(tag)


if __name__ == '__main__':
    unittest.main()
