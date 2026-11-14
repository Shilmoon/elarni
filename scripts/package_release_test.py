"""Process-level checks of candidate packaging and public source selection."""
import ctypes
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
from release_support import version  # noqa: E402
# elarni.exe imports all three and elarni_domain.dll imports vcruntime140.dll; a clean Windows has none.
VC_RUNTIME = ('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')


def product_version(value):
    """The ProductVersion entry of a version resource, laid out as the Windows runner's is."""
    key, text = 'ProductVersion\0'.encode('utf-16-le'), (value + '\0').encode('utf-16-le')
    return struct.pack('<HHH', 6 + len(key) + len(text), len(text) // 2, 1) + key + text


def msi_rows(installer, query):
    """Every row of a read-only query on an MSI database, as strings."""
    msi = ctypes.WinDLL('msi')
    database, view, record = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_ulong()
    if msi.MsiOpenDatabaseW(str(installer), None, ctypes.byref(database)):
        raise OSError('Cannot open ' + str(installer))
    rows = []
    try:
        if msi.MsiDatabaseOpenViewW(database, query, ctypes.byref(view)) or msi.MsiViewExecute(view, 0):
            raise OSError('Cannot run ' + query)
        while msi.MsiViewFetch(view, ctypes.byref(record)) == 0:
            row = []
            for field in range(1, msi.MsiRecordGetFieldCount(record) + 1):
                size = ctypes.c_ulong(4096)
                value = ctypes.create_unicode_buffer(size.value)
                msi.MsiRecordGetStringW(record, field, value, ctypes.byref(size))
                row.append(value.value)
            msi.MsiCloseHandle(record)
            rows.append(row)
        msi.MsiCloseHandle(view)
    finally:
        msi.MsiCloseHandle(database)
    return rows


def msi_condition(installer, condition, properties):
    """Whether Windows Installer would run an action with this condition, given these properties."""
    msi = ctypes.WinDLL('msi')
    package = ctypes.c_ulong()
    # Ignoring the machine state opens the package for queries only; nothing is installed.
    if msi.MsiOpenPackageExW(str(installer), 1, ctypes.byref(package)):
        raise OSError('Cannot open package ' + str(installer))
    try:
        for name, value in properties.items():
            msi.MsiSetPropertyW(package, name, value)
        result = msi.MsiEvaluateConditionW(package, condition)
    finally:
        msi.MsiCloseHandle(package)
    if result not in (0, 1):
        raise ValueError('Invalid MSI condition: ' + condition)
    return result == 1


class PackageReleaseChecks(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'native macOS packager requires macOS')
    def test_macos_packaging_cannot_write_inside_its_input_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'Fixture.app'
            app.mkdir()
            output = app / 'output'
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/package-macos'),
                                     '--app', str(app), '--output', str(output), '--unsigned'],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Output must be outside the input app or archive', result.stderr)
            self.assertFalse(output.exists())

    def test_linux_packaging_cannot_write_inside_its_input_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / 'bundle'
            bundle.mkdir()
            output = bundle / 'release'
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/package-linux'),
                                     '--bundle', str(bundle), '--output', str(output)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Output must be outside the input bundle', result.stderr)
            self.assertFalse(output.exists())

    def test_source_archive_covers_every_platform_and_excludes_local_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'output'
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/package-source'),
                                     '--output', str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            archive, = output.glob('*.tar.gz')
            with tarfile.open(archive) as package:
                paths = {Path(entry.name).relative_to(archive.name.removesuffix('.tar.gz')).as_posix()
                         for entry in package.getmembers()}
            for required in ('windows/runner/CMakeLists.txt', 'linux/CMakeLists.txt',
                             'macos/Runner.xcodeproj/project.pbxproj', 'lib/main.dart',
                             'Cargo.lock', 'pubspec.lock', 'go.work', 'android/app/src/main/AndroidManifest.xml',
                             'android/app/src/main/java/com/elarni/Repository.kt', 'android/gradle/wrapper/gradle-wrapper.jar',
                             'android/app/src/main/assets/server-locations.json',
                             'android/OPEN_SOURCE_NOTICES', 'android/README.md',
                             'ios/README.md', 'ios/Elarni/Elarni.xcodeproj/project.pbxproj',
                             'ios/Elarni/Elarni/Info.plist', 'ios/Elarni/ElarniPacketTunnel/Info.plist',
                             'ios/Elarni/Elarni/Shared/SubscriptionStore.swift',
                             'scripts/export-android-locations.dart',
                             'scripts/build-android-native', 'scripts/check-android',
                             'scripts/check-android-release', 'docs/BRANDING.md', 'README.md',
                             'scripts/tuic_fixture.py', 'scripts/package-dependencies',
                             'Vendor/Xray-core/proxy/tuic/client.go',
                             'Vendor/Xray-core/infra/conf/tuic.go',
                             'Vendor/libXray/share/tuic_traffic_test.go',
                             'Vendor/Xray-core/transport/internet/websocket/connection_test.go',
                             'assets/branding/elarni-mark.png',
                             'assets/branding/elarni-app-icon.png'):
                self.assertTrue(required in paths, 'Missing public source: ' + required)
            self.assertFalse(any(set(Path(path).parts) &
                                 {'.git', '.build', '.toolchains', '.gradle', '.kotlin', 'Evidence', 'artifacts'}
                                 for path in paths))
            self.assertFalse(any(path.endswith(('local.properties', '.jks', '.keystore', '.apk', '.aab', 'GeneratedPluginRegistrant.java')) for path in paths))
            self.assertEqual(paths, set(json.loads((output / 'project-source-manifest.json').read_text())))

    def run_package(self, bundle, output, success=True, extra=()):
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/package-windows'),
                                 '--bundle', str(bundle), '--output', str(output), '--unsigned', *extra],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def bundle(self, root):
        bundle = root / 'bundle with spaces'
        bundle.mkdir()
        # Minimal PE/COFF fixtures, never executed.
        pe = bytearray(128)
        pe[:2] = b'MZ'
        struct.pack_into('<I', pe, 60, 64)
        pe[64:68] = b'PE\0\0'
        struct.pack_into('<H', pe, 68, 0x8664)
        for name in ('elarni.exe', 'elarni-core.exe', 'elarni-cli.exe',
                     'elarni_domain.dll', 'flutter_windows.dll', 'wintun.dll', *VC_RUNTIME):
            (bundle / name).write_bytes(pe)
        (bundle / 'elarni.exe').write_bytes(pe + product_version(version()))
        for name in ('LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES', 'GOZXING_LICENSE.txt',
                     'XERRORS_LICENSE.txt', 'WIREGUARD_WINDOWS_LICENSE.txt', 'WINTUN_LICENSE.txt'):
            (bundle / name).write_text('synthetic license fixture')
        assets = bundle / 'data/flutter_assets'
        assets.mkdir(parents=True)
        (assets / 'AssetManifest.bin').write_bytes(b'fixture')
        (bundle / 'data/icudtl.dat').write_bytes(b'fixture')
        (bundle / 'data/app.so').write_bytes(b'fixture')
        return bundle

    def test_complete_candidate_archive_has_assets_and_exact_hash_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = self.bundle(root)
            output = root / 'output'
            self.run_package(bundle, output)
            archive, = output.glob('*.zip')
            self.assertIn('UNSIGNED', archive.name)
            with zipfile.ZipFile(archive) as package:
                self.assertIsNone(package.testzip())
                self.assertTrue(any(name.endswith('/data/flutter_assets/AssetManifest.bin') for name in package.namelist()))
                self.assertTrue(any(name.endswith('/LICENSE') for name in package.namelist()))
            receipt = json.loads((output / 'release-manifest.json').read_text())
            self.assertEqual(receipt['distribution'], 'unsigned-candidate')
            self.assertEqual(receipt['artifacts'][0]['sha256'], hashlib.sha256(archive.read_bytes()).hexdigest())
            self.assertIn('version: ' + receipt['version'], (ROOT / 'pubspec.yaml').read_text())
            failed = self.run_package(bundle, output, success=False)
            self.assertIn('Output directory must be empty', failed.stderr)

    def test_incomplete_or_wrong_architecture_bundle_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = self.bundle(root)
            (bundle / 'elarni-core.exe').write_bytes(b'not a PE binary')
            failed = self.run_package(bundle, root / 'bad-pe', success=False)
            self.assertIn('Expected x64 PE binary', failed.stderr)
            (bundle / 'LICENSE').unlink()
            failed = self.run_package(bundle, root / 'missing-license', success=False)
            self.assertIn('Missing or empty bundle component: LICENSE', failed.stderr)

    def test_stale_build_is_not_packaged_under_the_new_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = self.bundle(root)
            pe = (bundle / 'elarni-core.exe').read_bytes()
            for name, binary in (('stale', pe + product_version('0.0.1+1')), ('unversioned', pe)):
                with self.subTest(name):
                    (bundle / 'elarni.exe').write_bytes(binary)
                    failed = self.run_package(bundle, root / name, success=False)
                    self.assertIn('Bundle version differs from pubspec.yaml', failed.stderr)
                    self.assertFalse(any((root / name).glob('*.zip')))

    @unittest.skipUnless(sys.platform == 'linux' and shutil.which('dpkg-deb'), 'the Linux packager runs on Linux')
    def test_stale_linux_build_is_not_packaged_under_the_new_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / 'bundle'
            (bundle / 'data/flutter_assets').mkdir(parents=True)
            for name in ('LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES', 'GOZXING_LICENSE.txt', 'XERRORS_LICENSE.txt'):
                (bundle / name).write_text('synthetic license fixture')
            (bundle / 'data/flutter_assets/version.json').write_text(
                json.dumps({'app_name': 'elarni', 'version': '0.0.1', 'build_number': '1'}))
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/package-linux'), '--bundle', str(bundle),
                                     '--output', str(Path(temporary) / 'output')], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Bundle version differs from pubspec.yaml', result.stderr)

    def test_bundle_without_the_vc_runtime_is_rejected(self):
        for name in VC_RUNTIME:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                bundle = self.bundle(root)
                (bundle / name).unlink()
                failed = self.run_package(bundle, root / 'output', success=False)
                self.assertIn('Missing or empty bundle component: ' + name, failed.stderr)

    @unittest.skipUnless(sys.platform == 'win32' and shutil.which('wix'), 'WiX Toolset v5 builds the MSI on Windows')
    def test_msi_ships_the_vc_runtime_and_removes_the_helper_on_uninstall(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / 'output'
            self.run_package(self.bundle(root), output, extra=['--msi'])
            installer, = output.glob('*.msi')
            directories = dict(msi_rows(installer, 'SELECT `Component`, `Directory_` FROM `Component`'))
            files = {name.split('|')[-1]: directories[component]
                     for name, component in msi_rows(installer, 'SELECT `FileName`, `Component_` FROM `File`')}
            for name in VC_RUNTIME:
                self.assertEqual(files.get(name), files['elarni.exe'], name + ' is not installed next to elarni.exe')
            # An upgrade from a build with a newer runtime must still copy these files.
            self.assertEqual(msi_rows(installer, "SELECT `Value` FROM `Property` WHERE `Property` = 'REINSTALLMODE'"), [['amus']])
            cleanup = [row for row in msi_rows(installer, 'SELECT `Action`, `Type`, `Source`, `Target` FROM `CustomAction`')
                       if '--uninstall-helper' in row[3]]
            self.assertEqual(len(cleanup), 1, 'The MSI does not remove %ProgramFiles%\\Elarni VPN Helper')
            action, kind, source, target = cleanup[0]
            # An EXE in a directory (34), run deferred (0x400) as LocalSystem (0x800, no impersonation);
            # a failure is ignored (0x40) so it can never roll back the uninstall.
            self.assertEqual((source, int(kind)), ('INSTALLFOLDER', 34 | 0x40 | 0x400 | 0x800))
            self.assertTrue(target.startswith('"[INSTALLFOLDER]elarni-core.exe"'), target)
            sequence = {name: (condition, int(number)) for name, condition, number in
                        msi_rows(installer, 'SELECT `Action`, `Condition`, `Sequence` FROM `InstallExecuteSequence`')}
            condition, number = sequence[action]
            self.assertLess(number, sequence['RemoveFiles'][1], 'The cleanup needs the installed core')
            # A major upgrade removes the old product with UPGRADINGPRODUCTCODE set; the helper stays.
            for properties, runs in (({'REMOVE': 'ALL'}, True), ({}, False),
                                     ({'REMOVE': 'ALL', 'UPGRADINGPRODUCTCODE': '{00000000-0000-0000-0000-000000000001}'}, False)):
                self.assertEqual(msi_condition(installer, condition, properties), runs, properties)

    @unittest.skipUnless(sys.platform == 'win32' and shutil.which('wix'), 'WiX Toolset v5 builds the MSI on Windows')
    def test_msi_offers_connecting_without_the_consent_prompt_once_per_account(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / 'output'
            self.run_package(self.bundle(root), output, extra=['--msi'])
            installer, = output.glob('*.msi')
            actions = msi_rows(installer, 'SELECT `Action`, `Type`, `Source`, `Target` FROM `CustomAction`')
            allow = [row for row in actions if '--vpn-service' in row[3]]
            self.assertEqual(len(allow), 1, 'The MSI does not allow the installing account in the VPN service')
            action, kind, source, target = allow[0]
            # Deferred as LocalSystem; a failure is ignored, so the consent prompt stays the fallback.
            self.assertEqual((source, int(kind)), ('INSTALLFOLDER', 34 | 0x40 | 0x400 | 0x800))
            self.assertEqual(target, '"[INSTALLFOLDER]elarni-core.exe" --vpn-service add [UserSID]')
            install, = [row[0] for row in actions if '--install-helper' in row[3]]
            sequence = {name: (condition, int(number)) for name, condition, number in
                        msi_rows(installer, 'SELECT `Action`, `Condition`, `Sequence` FROM `InstallExecuteSequence`')}
            condition, number = sequence[action]
            self.assertGreater(number, sequence[install][1], 'The service runs the helper copy installed before it')
            # The installer marks the account it offered the service to, and reads that mark back.
            marker = ['1', 'Software\\Elarni\\Installer', 'VPNServiceOffered']
            self.assertIn(marker, [row[:3] for row in msi_rows(installer, 'SELECT `Root`, `Key`, `Name` FROM `Registry`')])
            self.assertIn(marker, [row[1:4] for row in msi_rows(installer, 'SELECT `Signature_`, `Root`, `Key`, `Name` FROM `RegLocator`')])
            # An upgrade offers it once, to an account that never had it; later upgrades and repairs
            # keep the choice each account made in Settings, as does an upgrade beside an existing service.
            upgrade = {'WIX_UPGRADE_DETECTED': '{00000000-0000-0000-0000-000000000001}'}
            for properties, runs in (({}, True), ({'Installed': '00:00:00'}, False), (upgrade, True),
                                     ({**upgrade, 'VPNSERVICEOFFERED': '#1'}, False),
                                     ({**upgrade, 'VPNSERVICEEXISTS': '#%"C:\\helper\\elarni-core.exe" --service S-1-5-21-1'}, False)):
                self.assertEqual(msi_condition(installer, condition, properties), runs, properties)

    def test_diagnostic_candidate_is_labeled_and_contains_export_launcher(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = self.bundle(root)
            self.run_package(bundle, root / 'missing', success=False, extra=['--diagnostics'])
            core = bundle / 'elarni-core.exe'
            release_core = core.read_bytes()
            # A diagnostic core without its launcher files is still a diagnostic build.
            core.write_bytes(release_core + b'--diagnostics-export')
            failed = self.run_package(bundle, root / 'unlabeled-core', success=False)
            self.assertIn('Diagnostic build detected', failed.stderr)
            core.write_bytes(release_core)
            for name in ('Export diagnostics.cmd', 'DIAGNOSTICS.txt', 'BUILD-INFO.json'):
                (bundle / name).write_text('synthetic diagnostic fixture')
            failed = self.run_package(bundle, root / 'unlabeled', success=False)
            self.assertIn('Diagnostic build detected', failed.stderr)
            self.run_package(bundle, root / 'output', extra=['--diagnostics'])
            archive, = (root / 'output').glob('*.zip')
            self.assertIn('DIAGNOSTICS', archive.name)
            with zipfile.ZipFile(archive) as package:
                self.assertTrue(any(name.endswith('/Export diagnostics.cmd') for name in package.namelist()))

    @unittest.skipIf(sys.platform == 'win32', 'symlink creation requires Windows developer privileges')
    def test_bundle_cannot_copy_an_external_file_through_a_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = self.bundle(root)
            external = root / 'external-fixture'
            external.write_text('must not enter package')
            (bundle / 'escaped').symlink_to(external)
            failed = self.run_package(bundle, root / 'output', success=False)
            self.assertIn('External bundle symlink', failed.stderr)


if __name__ == '__main__':
    unittest.main()
