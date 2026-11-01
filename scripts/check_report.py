#!/usr/bin/env python3
"""Retain a replayable transcript of synthetic checks without collecting inputs."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import signal
import threading
import subprocess
import sys
import tempfile

REPORT_ENV = 'ELARNI_CHECK_REPORT'


def now():
    return datetime.now(timezone.utc).isoformat()


def git_output(root, *args):
    try:
        return subprocess.check_output(['git', '-C', str(root), *args],
                                       stderr=subprocess.DEVNULL, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def run(command, root=None):
    if os.environ.get(REPORT_ENV):
        return subprocess.call(command)
    root = Path(root or Path.cwd())
    output = root / '.build/check-results'
    output.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), dir=output))
    report_path = directory / 'summary.json'
    report = {
        'schemaVersion': 1, 'status': 'running', 'exitCode': None,
        'command': command, 'cwd': str(Path.cwd()), 'platform': platform.platform(),
        'python': platform.python_version(), 'startedAt': now(), 'finishedAt': None,
        'revision': git_output(root, 'rev-parse', 'HEAD'),
        'worktreeStatus': git_output(root, 'status', '--porcelain=v1', '--untracked-files=normal'),
        'transcript': 'output.log',
    }

    def save():
        temporary = report_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(report, indent=2) + '\n')
        temporary.replace(report_path)

    def interrupted(number, _frame):
        report['signal'] = number
        raise KeyboardInterrupt

    save()
    child = reader = None
    signals = [signal.SIGINT, signal.SIGTERM]
    if os.name == 'nt':
        signals.append(signal.SIGBREAK)
    handlers = {number: signal.signal(number, interrupted) for number in signals}
    try:
        with (directory / 'output.log').open('wb') as transcript:
            try:
                child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         env=dict(os.environ, **{REPORT_ENV: str(directory)}),
                                         start_new_session=os.name != 'nt',
                                         creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == 'nt' else 0)
                def copy():
                    while chunk := child.stdout.read1(65536):
                        transcript.write(chunk)
                        transcript.flush()
                        sys.stdout.buffer.write(chunk)
                        sys.stdout.buffer.flush()
                reader = threading.Thread(target=copy, daemon=True)
                reader.start()
                # Windows never interrupts a blocking pipe read for a console
                # control event; short joins let the signal handler run.
                while reader.is_alive():
                    reader.join(.1)
                code = child.wait()
                report.update(status='completed', exitCode=code if code >= 0 else 128 - code)
                if code < 0:
                    report.update(status='interrupted', signal=-code)
            except KeyboardInterrupt:
                report.update(status='interrupted', exitCode=128 + report.get('signal', signal.SIGINT))
            except OSError as error:
                message = f'{type(error).__name__}: {error}\n'
                transcript.write(message.encode())
                print(message, file=sys.stderr, end='')
                report.update(status='error', exitCode=127)
            finally:
                if child is not None:
                    if child.poll() is None:
                        if os.name == 'nt':
                            try:
                                child.send_signal(signal.CTRL_BREAK_EVENT)
                            except OSError:
                                child.terminate()
                        else:
                            try:
                                os.killpg(child.pid, signal.SIGINT)
                            except ProcessLookupError:
                                pass  # The child can exit between poll and signal.
                        try:
                            child.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            if os.name == 'nt':
                                child.kill()
                            else:
                                try:
                                    os.killpg(child.pid, signal.SIGKILL)
                                except ProcessLookupError:
                                    pass
                            child.wait()
                    if reader is not None:
                        reader.join(5)  # A surviving grandchild may hold the pipe.
                    child.stdout.close()
    finally:
        for number, handler in handlers.items():
            signal.signal(number, handler)
        report['finishedAt'] = now()
        if report['status'] == 'running':
            report.update(status='incomplete', exitCode=1)
        save()
        print(f'Check report: {report_path}', flush=True)
    return report['exitCode']


def record_check(root):
    """Re-execute a Python entrypoint once; nested checks use the outer report."""
    if not os.environ.get(REPORT_ENV):
        raise SystemExit(run([sys.executable, *sys.argv], root))


if __name__ == '__main__':
    command = sys.argv[1:]
    if command[:1] == ['--']:
        command = command[1:]
    if not command:
        raise SystemExit('usage: python scripts/check_report.py -- COMMAND [ARG ...]')
    raise SystemExit(run(command))
