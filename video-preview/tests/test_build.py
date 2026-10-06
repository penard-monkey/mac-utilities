"""Script tests for Video Preview: the pinned VLCKit fetch, plist consistency,
and a real build checked for the flat-dylib relink, signatures and entitlements.

The build test needs Xcode and either network access or a cached VLCKit
archive; set VIDEO_PREVIEW_SKIP_BUILD_TESTS=1 to skip it."""
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest

UTILITY = Path(__file__).resolve().parents[1]
ROOT = UTILITY.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT/'scripts/release'))
spec = importlib.util.spec_from_file_location('release_build', ROOT/'scripts/release/build.py')
release_build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_build)


def xcode_available():
    try:
        return subprocess.run(['/usr/bin/xcodebuild', '-version'], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        return False


class FetchTests(unittest.TestCase):
    def test_pinned_official_https_url_and_sha256(self):
        script = (UTILITY/'scripts/fetch-vlckit.sh').read_text()
        self.assertRegex(script, r'VLCKIT_URL="https://download\.videolan\.org/pub/cocoapods/prod/VLCKit-3\.7\.3-[^"]+\.tar\.xz"')
        self.assertRegex(script, r'VLCKIT_SHA256="[0-9a-f]{64}"')

    def test_checksum_mismatch_fails_and_discards_the_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp)/'cache'
            cache.mkdir()
            archive = cache/'VLCKit-3.7.3.tar.xz'
            archive.write_bytes(b'not vlckit')
            result = subprocess.run(['/bin/bash', str(UTILITY/'scripts/fetch-vlckit.sh'), str(Path(temp)/'Vendor')],
                                    env=dict(os.environ, VLCKIT_CACHE=str(cache)), text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('SHA-256 mismatch', result.stdout)
            self.assertFalse(archive.exists())
            self.assertFalse((Path(temp)/'Vendor').exists())


class PlistTests(unittest.TestCase):
    def test_every_previewed_type_is_declared_by_the_host_app(self):
        ext = plistlib.loads((UTILITY/'QuickLookExtension/Info.plist').read_bytes())
        app = plistlib.loads((UTILITY/'App/Info.plist').read_bytes())
        supported = ext['NSExtension']['NSExtensionAttributes']['QLSupportedContentTypes']
        declared = [t['UTTypeIdentifier'] for t in app['UTImportedTypeDeclarations']]
        self.assertEqual(sorted(supported), sorted(declared))
        self.assertIn('org.matroska.mkv', supported)
        self.assertEqual(ext['NSExtension']['NSExtensionPointIdentifier'], 'com.apple.quicklook.preview')

    def test_extension_entitlements_are_exactly_the_proven_set(self):
        entitlements = plistlib.loads((UTILITY/'QuickLookExtension/QuickLookExtension.entitlements').read_bytes())
        self.assertEqual(entitlements, {'com.apple.security.app-sandbox': True,
                                        'com.apple.security.files.user-selected.read-only': True})


@unittest.skipIf(os.environ.get('VIDEO_PREVIEW_SKIP_BUILD_TESTS') == '1' or not xcode_available(),
                 'needs Xcode (set VIDEO_PREVIEW_SKIP_BUILD_TESTS=1 to skip)')
class BuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        base = Path(cls.temp.name)
        license = base/'LICENSE'
        license.write_text('MIT test license\n')
        cache = os.environ.get('VIDEO_PREVIEW_TEST_CACHE', str(Path.home()/'.cache/worktrees/mac-utilities/video-preview-tests'))
        result = subprocess.run(['/bin/bash', str(UTILITY/'scripts/build.sh'), '--output', str(base/'out'), '--dev',
                                 '--version', '9.8.7', '--vendor', cache+'/Vendor', '--scratch', str(base/'scratch'),
                                 '--license', str(license)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode:
            raise AssertionError(result.stdout[-8000:])
        cls.app = base/'out/Video Preview Dev.app'
        cls.appex = cls.app/'Contents/PlugIns/VideoPreviewQuickLook.appex'
        cls.dylib = cls.appex/'Contents/Frameworks/VLCKit.dylib'

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def output(self, *args):
        return subprocess.check_output([str(a) for a in args], text=True, stderr=subprocess.STDOUT)

    def test_vlckit_is_one_flat_relinked_dylib(self):
        self.assertEqual([p for p in self.app.rglob('*') if p.is_symlink()], [])
        self.assertFalse(list(self.app.rglob('*.framework')))
        self.assertIn('@rpath/VLCKit.dylib', self.output('/usr/bin/otool', '-D', '-arch', 'arm64', self.dylib))
        links = self.output('/usr/bin/otool', '-L', self.appex/'Contents/MacOS/VideoPreviewQuickLook')
        self.assertIn('@rpath/VLCKit.dylib', links)
        self.assertNotIn('VLCKit.framework', links)

    def test_signatures_entitlements_and_identity(self):
        self.output('/usr/bin/codesign', '--verify', '--deep', '--strict', self.app)
        for path in (self.dylib, self.appex, self.app):
            self.assertIn('Signature=adhoc', self.output('/usr/bin/codesign', '-dv', path))
        entitlements = subprocess.check_output(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(self.appex)],
                                               stderr=subprocess.DEVNULL)
        self.assertEqual(plistlib.loads(entitlements), {'com.apple.security.app-sandbox': True,
                                                        'com.apple.security.files.user-selected.read-only': True})
        app_entitlements = subprocess.check_output(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(self.app)],
                                                   stderr=subprocess.DEVNULL)
        self.assertEqual(app_entitlements.strip(), b'')
        info = plistlib.loads((self.app/'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'com.mac-utilities.video-preview.dev')
        self.assertEqual(info['CFBundleShortVersionString'], '9.8.7')
        ext = plistlib.loads((self.appex/'Contents/Info.plist').read_bytes())
        self.assertEqual(ext['CFBundleIdentifier'], 'com.mac-utilities.video-preview.dev.quicklook')

    def test_licenses_ship_in_resources(self):
        resources = self.app/'Contents/Resources'
        self.assertIn('GNU LESSER GENERAL PUBLIC LICENSE', (resources/'VLCKit-LGPL-2.1.txt').read_text())
        self.assertIn('VLCKit 3.7.3', (resources/'THIRD_PARTY_NOTICES.md').read_text())
        self.assertEqual((resources/'LICENSE').read_text(), 'MIT test license\n')

    def test_release_verification_accepts_the_bundle(self):
        app = {'name': self.app.name, 'bundle_id': 'com.mac-utilities.video-preview.dev',
               'extensions': ['VideoPreviewQuickLook.appex']}
        release_build.verify_bundle(self.app, app, '9.8.7')
        with self.assertRaises(ValueError):
            release_build.verify_bundle(self.app, dict(app, bundle_id='com.example.other'), '9.8.7')


if __name__ == '__main__':
    unittest.main()
