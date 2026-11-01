"""Signed App Sandbox IPC only; owns a test container, never uses VPN APIs."""
import json
import pathlib
import plistlib
import select
import shutil
import socket
import subprocess
import sys
import tempfile


def run(executable):
    with tempfile.TemporaryDirectory(prefix='rv-sandbox-build-') as build:
        app = pathlib.Path(build) / 'ControlFixture.app'
        binary = app / 'Contents/MacOS/ControlFixture'
        binary.parent.mkdir(parents=True)
        shutil.copy2(executable, binary)
        identifier = 'com.elarni.control-checks'
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'ControlFixture',
            'CFBundlePackageType': 'APPL'}))
        entitlements = pathlib.Path(build) / 'entitlements.plist'
        entitlements.write_bytes(plistlib.dumps({
            'com.apple.security.app-sandbox': True,
            'com.apple.security.network.client': True,
            'com.apple.security.network.server': True}))
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(app)], check=True)
        control = pathlib.Path.home() / 'Library/Containers' / identifier / 'Data/check/control.sock'
        children = []

        def launch():
            process = subprocess.Popen([str(binary), str(control)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            children.append(process)
            ready = select.select([process.stdout], [], [], 15)[0]
            line = process.stdout.readline() if ready else ''
            if line.strip() != 'READY':
                process.kill()
                _, errors = process.communicate(timeout=5)
                raise AssertionError('sandbox transport failed: ' + line + errors)
            return process

        def request(value):
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(5)
                client.connect(str(control))
                client.sendall(json.dumps(value).encode() + b'\n')
                with client.makefile('rb') as stream:
                    return json.loads(stream.readline(4096))

        try:
            process = launch()
            assert control.stat().st_mode & 0o777 == 0o600
            assert control.parent.stat().st_mode & 0o777 == 0o700
            assert request({'command': 'status'}) == {'success': True, 'data': {'fixture': True}}
            print('PASS signed App Sandbox Unix IPC, private modes and external same-user request')
            duplicate = subprocess.run([str(binary), str(control)], capture_output=True, text=True, timeout=15)
            assert duplicate.returncode != 0, 'duplicate process replaced endpoint owner'
            assert request({'command': 'status'})['success']
            print('PASS second process cannot take endpoint ownership')
            process.kill()
            process.wait(timeout=5)
            process = launch()
            assert request({'command': 'status'})['success']
            assert request({'command': 'shutdown', 'ownerPid': -1})['error'] == 'different_daemon_owner'
            assert process.poll() is None
            print('PASS crash releases ownership; stale owner shutdown cannot stop replacement')
            assert request({'command': 'shutdown'})['success']
            assert process.wait(timeout=10) == 0
            assert not control.exists()
            print('PASS sandbox shutdown cleans endpoint')
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=5)
        print('4 sandbox transport checks passed; no VPN controller loaded')


if __name__ == '__main__':
    run(pathlib.Path(sys.argv[1]).resolve(strict=True))
