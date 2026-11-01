"""Exercise change-based check selection through git in a scratch repository."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('check-changed').resolve()
DESKTOP = sys.platform != 'darwin'


class CheckChangedSelection(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='elarni-changed-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / 'scripts').mkdir()
        shutil.copy(SCRIPT, self.root / 'scripts/check-changed')
        for path in ('lib/app.dart', 'native/elarni-domain/src/lib.rs', 'README.md'):
            self.write(path)
        self.git('init', '-q')
        self.git('add', '-A')
        self.git('commit', '-qm', 'fixture')

    def write(self, path, text='x\n'):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def git(self, *args):
        subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'core.autocrlf=false', *args],
                       cwd=self.root, check=True, capture_output=True)

    def selection(self, *args):
        result = subprocess.run([sys.executable, str(self.root / 'scripts/check-changed'), '--dry-run', *args],
                                cwd=self.root, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.split(), result.stderr

    def test_dart_library_edit_runs_flutter_and_the_desktop_flow(self):
        self.write('lib/app.dart', 'changed\n')
        self.assertEqual(self.selection()[0], ['flutter', 'windows'] if DESKTOP else ['flutter'])

    def test_untracked_and_deleted_files_select_their_checks(self):
        self.write('Vendor/Xray-core/proxy/new.go')
        (self.root / 'native/elarni-domain/src/lib.rs').unlink()
        self.assertEqual(self.selection()[0], ['go', 'rust', 'windows'] if DESKTOP else ['go', 'rust', 'swift'])

    def test_documentation_only_runs_nothing(self):
        self.write('README.md', 'changed\n')
        self.write('docs/guide.md')
        self.assertEqual(self.selection(), ([], ''))

    def test_base_covers_committed_work_and_paths_with_spaces(self):
        self.write('test/a b_test.dart')
        self.git('add', '-A')
        self.git('commit', '-qm', 'work')
        self.assertEqual(self.selection()[0], [])
        self.assertEqual(self.selection('--base', 'HEAD~1')[0], ['flutter'])

    def test_images_the_desktop_flow_picks_run_it(self):
        self.write('test/windows_routing_qr.png')
        self.assertEqual(self.selection()[0], ['flutter', 'windows'] if DESKTOP else ['flutter'])

    def test_scripts_and_tun2proxy_map_to_their_own_checks(self):
        self.write('scripts/release_support.py')
        self.write('Vendor/tun2proxy/src/lib.rs')
        self.assertEqual(self.selection()[0], ['rust', 'scripts'] if DESKTOP else ['rust', 'scripts', 'swift'])

    def test_failure_output_prints_on_a_legacy_console_code_page(self):
        # Flutter frames failures with box-drawing characters, which cp1251 cannot encode.
        (self.root / 'scripts/check-tests').write_bytes(b"#!/bin/sh\nprintf '\\342\\225\\220 failure\\n'\nexit 1\n")
        (self.root / 'scripts/check-windows').write_bytes(b'raise SystemExit(0)\n')
        self.git('add', '-A')
        self.git('commit', '-qm', 'fake checks')
        self.write('lib/app.dart', 'changed\n')
        result = subprocess.run([sys.executable, str(self.root / 'scripts/check-changed')], cwd=self.root,
                                capture_output=True, timeout=60, env=dict(os.environ, PYTHONIOENCODING='cp1251'))
        self.assertNotIn(b'Traceback', result.stderr)
        self.assertIn(b'failure', result.stdout)
        self.assertIn(b'FAILED: flutter', result.stdout)
        self.assertEqual(result.returncode, 1)

    def test_all_selects_every_ci_check_for_this_os_without_changes(self):
        expected = {'darwin': ['flutter', 'go', 'rust', 'scripts', 'swift'],
                    'linux': ['flutter', 'go', 'lint', 'race', 'rust', 'scripts', 'windows']}
        self.assertEqual(self.selection('--all')[0], expected.get(sys.platform, ['flutter', 'go', 'rust', 'scripts', 'windows']))

    def test_unmapped_platform_code_is_reported_not_ignored(self):
        self.write('android/app/Main.kt')
        selected, notes = self.selection()
        self.assertEqual(selected, [])
        self.assertIn('android/app/Main.kt', notes)


if __name__ == '__main__':
    unittest.main()
