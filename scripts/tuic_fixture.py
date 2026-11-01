"""Disposable TUIC peer for the existing platform acceptance fixtures.

Requires the pinned, separately built sing-box test binary; never configures TUN,
routes, DNS or an installed app on the host. Optional port overrides terminate
Android/Windows traffic at loopback responders. Linux supplies its controlled
destinations inside the check runner's private network namespace.
"""
import base64
from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


@contextmanager
def android_tuic_peer(root, tcp_port=None, udp_port=None, *, listen_host='127.0.0.1', listen_port=0):
    binary = Path(os.environ.get('ELARNI_TUIC_SERVER', root / '.build/tuic/tools/sing-box'))
    if not binary.is_file():
        raise RuntimeError('Build the pinned sing-box TUIC fixture described in docs/TESTING.md first.')
    with tempfile.TemporaryDirectory(prefix='elarni-tuic-') as temporary:
        directory = Path(temporary)
        cert, key = directory / 'certificate.pem', directory / 'key.pem'
        # -nodes, not OpenSSL 3's -noenc: the Mac's LibreSSL accepts only -nodes.
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-batch',
                        '-subj', '/CN=tuic-fixture.example', '-addext', 'subjectAltName=DNS:tuic-fixture.example',
                        '-days', '1', '-keyout', str(key), '-out', str(cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        key.chmod(0o600)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
            reservation.bind((listen_host, listen_port))
            port = reservation.getsockname()[1]
        config = {'log': {'level': 'info'}, 'inbounds': [{
            'type': 'tuic', 'listen': listen_host, 'listen_port': port,
            'users': [{'uuid': '00000000-0000-4000-8000-000000000001', 'password': 'synthetic-tuic-only'}],
            'tls': {'enabled': True, 'alpn': ['h3'], 'certificate_path': str(cert), 'key_path': str(key)}}],
            'outbounds': [{'type': 'direct', 'tag': 'fixture'}],
            'route': {'rules': [{'network': network, 'action': 'route', 'outbound': 'fixture',
                                 'override_address': '127.0.0.1', 'override_port': target}
                                for network, target in [('tcp', tcp_port), ('udp', udp_port)] if target is not None]}}
        path = directory / 'server.json'
        path.write_text(json.dumps(config)); path.chmod(0o600)
        with (directory / 'server.log').open('w+') as log:
            process = subprocess.Popen([str(binary), 'run', '-c', str(path)], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 5
                while True:
                    log.seek(0)
                    if 'sing-box started' in log.read():
                        break
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError('Disposable TUIC peer did not start.')
                    time.sleep(0.02)
                yield port, base64.b64encode(cert.read_bytes()).decode('ascii')
            finally:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=3)
