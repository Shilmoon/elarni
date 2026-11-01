"""Loopback/self-contained regressions for the disposable suite's safety and oracle."""
import contextlib
import copy
import importlib.machinery
import importlib.util
import ipaddress
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest
from unittest import mock
import urllib.error
import urllib.request
import uuid

import AcceptanceResponder as responder

ROOT = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader("check_extension", str(ROOT / "scripts/check-extension"))
spec = importlib.util.spec_from_loader(loader.name, loader)
runner = importlib.util.module_from_spec(spec)
loader.exec_module(runner)

FIXTURE = {
    "disposableAccount": "elarni-test", "subscriptionID": "test-source", "nodeIDs": ["one", "two"],
    "probeURL": "https://responder.example/check", "expectedBody": "elarni-fixture",
    "network": {"ipv4": "192.0.2.1", "ipv6": "2001:db8::1", "tcpPort": 18081, "udpPort": 18082,
                "directEgress": ["192.0.2.2", "2001:db8::2"],
                "nodeEgress": {"one": ["192.0.2.3", "2001:db8::3"], "two": ["192.0.2.4", "2001:db8::4"]},
                "dnsIPv4Suffix": "v4.responder.example", "dnsIPv6Suffix": "v6.responder.example"}}


class RunnerChecks(unittest.TestCase):
    def validate(self, value, full=True):
        with tempfile.TemporaryDirectory(prefix="elarni-harness-") as directory:
            path = Path(directory) / "fixture.json"
            path.write_text(json.dumps(value))
            return runner.validate_fixture(path, full)

    def test_legacy_fixture_and_full_requirements(self):
        legacy = {key: value for key, value in FIXTURE.items() if key != "network"}
        self.assertEqual(self.validate(legacy, False), legacy)
        with self.assertRaisesRegex(ValueError, "network fixture"):
            self.validate(legacy)
        self.assertEqual(self.validate(FIXTURE), FIXTURE)

    def test_reject_ambiguous_or_incomplete_route_oracle(self):
        for mutate in [lambda net: net.update(ipv6="127.0.0.1"),
                       lambda net: net.update(tcpPort=True),
                       lambda net: net["nodeEgress"].update(one=["192.0.2.2"]),
                       lambda net: net["nodeEgress"].pop("two"),
                       lambda net: net.update(dnsIPv6Suffix=net["dnsIPv4Suffix"]),
                       lambda net: net.update(dnsIPv4Suffix="bad..example")]:
            fixture = copy.deepcopy(FIXTURE)
            mutate(fixture["network"])
            with self.assertRaises((ValueError, TypeError)):
                self.validate(fixture)

    def test_reject_credentials_and_duplicate_nodes(self):
        for key, value in [("probeURL", "https://user:secret@example/check"), ("nodeIDs", ["same", "same"])]:
            fixture = copy.deepcopy(FIXTURE)
            fixture[key] = value
            with self.assertRaises(ValueError):
                self.validate(fixture)

    def test_missing_acknowledgement_cannot_inspect_or_launch(self):
        with mock.patch.object(runner.subprocess, "check_output") as run:
            with self.assertRaisesRegex(ValueError, "disposable-machine"):
                runner.preflight(Path("unused"), FIXTURE, False)
            run.assert_not_called()

    def test_wrong_account_cannot_inspect_or_launch(self):
        with mock.patch.object(runner.platform, "system", return_value="Darwin"), \
             mock.patch.object(runner.platform, "machine", return_value="arm64"), \
             mock.patch.object(runner.pwd, "getpwuid", return_value=mock.Mock(pw_name="personal")), \
             mock.patch.object(runner.subprocess, "check_output") as run:
            with self.assertRaisesRegex(ValueError, "disposable account"):
                runner.preflight(Path("unused"), FIXTURE, True)
            run.assert_not_called()

    def test_build_only_never_requests_test_or_signing(self):
        with mock.patch.object(runner.platform, "system", return_value="Darwin"), \
             mock.patch.object(runner.platform, "machine", return_value="arm64"), \
             mock.patch.object(runner.shutil, "which", return_value="/test/tool"), \
             mock.patch.object(runner.subprocess, "call", return_value=0) as run, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(runner.main(["--build-only"]), 0)
            command = run.call_args.args[0]
            self.assertEqual(command[:3], ["xcodebuildmcp", "macos", "build"])
            options = json.loads(command[-1])
            self.assertIn("CODE_SIGNING_ALLOWED=NO", options["extraArgs"])
            self.assertTrue(options["buildForTesting"])
            self.assertNotIn("testRunnerEnv", options)

    def test_summary_refuses_zero_skipped_missing_and_partial_passes(self):
        good = {"result": "Passed", "totalTestCount": 11, "passedTests": 11,
                "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
        self.assertTrue(runner.check_summary(good, 11))
        for key, value in [("totalTestCount", 0), ("passedTests", 10), ("skippedTests", 1),
                           ("failedTests", 1), ("expectedFailures", 1), ("result", "Failed")]:
            self.assertFalse(runner.check_summary(dict(good, **{key: value}), 11))
        self.assertFalse(runner.check_summary({}, 11))

    def test_all_selected_identifiers_exist_once_in_xctest_sources(self):
        methods = []
        import re
        for name in ("ExtensionIntegrationTests.swift", "MacOSAcceptanceTests.swift"):
            methods += re.findall(r"func (test\w+)\(", (ROOT / "macos/Checks" / name).read_text())
        selected = [value.split("/")[1] for value in runner.CASES.values()]
        self.assertCountEqual(selected, methods)
        self.assertEqual(len(selected), len(set(selected)))


@contextlib.contextmanager
def servers(host):
    running = []
    threads = []
    try:
        for kind in ("http", "tcp", "udp"):
            server = responder.make_server(kind, host, 0, [ipaddress.ip_network(host)])
            running.append(server)
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .01}, daemon=True)
            threads.append(thread)
            thread.start()
        yield running
    finally:
        for server in running:
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join(timeout=2)


class ResponderChecks(unittest.TestCase):
    def test_tcp_retains_server_connection_identity_and_frames_partial_writes(self):
        with servers("127.0.0.1") as (_, tcp, _), socket.create_connection(tcp.server_address, timeout=3) as stream:
            with stream.makefile("rb") as reader:
                identities = []
                for _ in range(2):
                    nonce = str(uuid.uuid4()).encode()
                    stream.sendall(nonce[:8])
                    stream.sendall(nonce[8:] + b"\n")
                    data = json.loads(reader.readline(4096))
                    self.assertEqual(data["nonce"], nonce.decode())
                    self.assertEqual(data["peer"], "127.0.0.1")
                    identities.append(data["connection"])
                self.assertEqual(identities[0], identities[1])

    def test_http_exact_body_and_invalid_udp_payload_rejection(self):
        with servers("127.0.0.1") as (http, _, udp):
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open("http://127.0.0.1:%d/check?nonce=%s" % (http.server_address[1], uuid.uuid4()), timeout=3) as reply:
                self.assertEqual(reply.status, 200)
                self.assertEqual(reply.read(), b"elarni-fixture")
                self.assertEqual(reply.headers["Cache-Control"], "no-store")
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as stream:
                stream.settimeout(.2)
                stream.sendto(b"invalid", udp.server_address)
                with self.assertRaises(socket.timeout):
                    stream.recvfrom(4096)

    def test_swift_oracle_real_tcp_udp_ipv4_ipv6(self):
        executable = os.environ.get("ELARNI_ACCEPTANCE_PROBE_CHECK")
        self.assertTrue(executable and Path(executable).is_file(), "run scripts/check-macos-harness")
        for host in ("127.0.0.1", "::1"):
            with self.subTest(family=host), servers(host) as (_, tcp, udp):
                result = subprocess.run([executable, host, str(tcp.server_address[1]), str(udp.server_address[1])],
                                        capture_output=True, text=True, timeout=40)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
