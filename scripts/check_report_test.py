"""Exercise the report command through real child processes and filesystem output."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

RECORDER = Path(__file__).with_name('check_report.py').resolve()


class CheckReportIntegration(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='elarni-report-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.env = os.environ.copy()
        self.env.pop('ELARNI_CHECK_REPORT', None)

    def run_check(self, command):
        return subprocess.run([sys.executable, str(RECORDER), '--', *command],
                              cwd=self.root, env=self.env, capture_output=True,
                              text=True, timeout=20)

    def reports(self):
        return sorted((self.root / '.build/check-results').glob('*/summary.json'))

    def test_success_retains_both_streams_and_replay_command(self):
        command = [sys.executable, '-c',
                   'import sys; print("fixture stdout"); print("fixture stderr", file=sys.stderr)']
        result = self.run_check(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        report_path, = self.reports()
        report = json.loads(report_path.read_text())
        self.assertEqual(report['command'], command)
        self.assertEqual(report['cwd'], str(self.root))
        self.assertEqual((report['status'], report['exitCode']), ('completed', 0))
        self.assertIsNotNone(report['finishedAt'])
        transcript = report_path.with_name('output.log').read_text()
        for expected in ('fixture stdout', 'fixture stderr'):
            self.assertIn(expected, transcript)
            self.assertIn(expected, result.stdout)

    def test_nonzero_and_missing_command_leave_failure_evidence(self):
        for command, code, status in (
            ([sys.executable, '-c', 'print("fixture failed"); raise SystemExit(7)'], 7, 'completed'),
            ([str(self.root / 'missing-fixture-command')], 127, 'error'),
        ):
            with self.subTest(command=command):
                before = set(self.reports())
                result = self.run_check(command)
                self.assertEqual(result.returncode, code, result.stderr)
                report_path, = set(self.reports()) - before
                report = json.loads(report_path.read_text())
                self.assertEqual((report['exitCode'], report['status']), (code, status))
                self.assertTrue(report_path.with_name('output.log').read_text().strip())

    def test_nested_runs_share_recording_and_repeat_runs_do_not_overwrite(self):
        command = [sys.executable, str(RECORDER), '--', sys.executable, '-c', 'print("nested fixture")']
        for _ in range(2):
            result = self.run_check(command)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.reports()), 2)
        for report in self.reports():
            self.assertIn('nested fixture', report.with_name('output.log').read_text())

    def test_interrupt_preserves_partial_output_and_waits_for_child_cleanup(self):
        code = '''from pathlib import Path
import signal, time
def stop(*args): raise SystemExit(130)
for name in ('SIGINT', 'SIGTERM', 'SIGBREAK'):
    if hasattr(signal, name): signal.signal(getattr(signal, name), stop)
try:
    print('partial diagnostic', flush=True)
    Path('ready').touch()
    for _ in range(600):  # Windows' sleep wakes early only for Ctrl+C, not Ctrl+Break.
        time.sleep(.1)
finally:
    Path('cleaned').touch()
'''
        process = subprocess.Popen([sys.executable, str(RECORDER), '--', sys.executable, '-c', code],
                                   cwd=self.root, env=self.env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True,
                                   creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == 'nt' else 0)
        try:
            deadline = time.monotonic() + 10
            while not (self.root / 'ready').exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((self.root / 'ready').exists(), 'child did not start')
            process.send_signal(signal.CTRL_BREAK_EVENT if os.name == 'nt' else signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=20)
            self.assertNotEqual(process.returncode, 0, (stdout, stderr))
            path, = self.reports()
            report = json.loads(path.read_text())
            self.assertEqual(report['status'], 'interrupted')
            self.assertEqual(report['exitCode'], process.returncode)
            self.assertTrue((self.root / 'cleaned').exists(), 'child cleanup did not finish')
            self.assertIn('partial diagnostic', path.with_name('output.log').read_text())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == '__main__':
    unittest.main(verbosity=2)
