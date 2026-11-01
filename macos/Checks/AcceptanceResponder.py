#!/usr/bin/env python3
"""Controlled HTTP/TCP/UDP responder for disposable macOS acceptance. No proxying."""
import argparse
import http.server
import ipaddress
import json
import signal
import socket
import socketserver
import threading
import uuid
from urllib.parse import parse_qs, urlsplit


def observation(nonce, address, connection):
    try:
        nonce = nonce.decode("ascii").strip() if isinstance(nonce, bytes) else nonce
        uuid.UUID(nonce)
    except (ValueError, UnicodeError, AttributeError):
        return None
    return (json.dumps({"nonce": nonce, "peer": str(ipaddress.ip_address(address)),
                        "connection": connection}, separators=(",", ":")) + "\n").encode()


class TCPHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(120)
        identity = str(uuid.uuid4())
        try:
            while True:
                nonce = self.rfile.readline(128)
                if not nonce or not nonce.endswith(b"\n"):
                    return
                data = observation(nonce, self.client_address[0], identity)
                if data is None:
                    return
                self.wfile.write(data)
                self.wfile.flush()
        except (OSError, TimeoutError):
            return


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        nonce, transport = self.request
        if len(nonce) > 128:
            return
        data = observation(nonce, self.client_address[0], str(uuid.uuid4()))
        if data is not None:
            transport.sendto(data, self.client_address)


class HTTPHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Never log client addresses, URLs, or incoming payloads.

    def do_GET(self):
        path = urlsplit(self.path)
        if path.path == "/check":
            data = self.server.expected_body
            content_type = "text/plain; charset=utf-8"
        elif path.path == "/observe":
            query = parse_qs(path.query)
            data = observation(query.get("nonce", [""])[0], self.client_address[0], str(uuid.uuid4()))
            content_type = "application/json"
        else:
            self.send_error(404)
            return
        if data is None:
            self.send_error(400)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


class AllowedServer:
    allow_reuse_address = True
    daemon_threads = True

    def verify_request(self, request, address):
        peer = ipaddress.ip_address(address[0])
        return any(peer in network for network in self.allowed)

    def handle_error(self, *_):
        pass  # Expected reset/timeouts during VPN failure tests; no raw payload logs.


def make_server(kind, host, port, allowed, body=b"elarni-fixture"):
    family = socket.AF_INET6 if ipaddress.ip_address(host).version == 6 else socket.AF_INET
    base, handler = {"http": (http.server.ThreadingHTTPServer, HTTPHandler),
                     "tcp": (socketserver.ThreadingTCPServer, TCPHandler),
                     "udp": (socketserver.ThreadingUDPServer, UDPHandler)}[kind]

    class Server(AllowedServer, base):
        address_family = family

        def server_bind(self):
            if family == socket.AF_INET6:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            super().server_bind()

    server = Server((host, port), handler, bind_and_activate=False)
    server.allowed = allowed
    server.expected_body = body
    try:
        server.server_bind()
        server.server_activate()
    except BaseException:
        server.server_close()
        raise
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", action="append", required=True, help="local IPv4/IPv6 bind address; repeat for both")
    parser.add_argument("--allow", action="append", required=True, help="allowed test-machine and node egress IP/CIDR; repeat")
    parser.add_argument("--http-port", type=int, default=18080)
    parser.add_argument("--tcp-port", type=int, default=18081)
    parser.add_argument("--udp-port", type=int, default=18082)
    parser.add_argument("--body", default="elarni-fixture", help="exact /check response, no trailing newline")
    args = parser.parse_args()
    for port in (args.http_port, args.tcp_port, args.udp_port):
        if not 1 <= port <= 65535:
            parser.error("ports must be in 1..65535")
    if args.http_port == args.tcp_port:
        parser.error("HTTP and TCP ports must differ")
    if not 0 < len(args.body.encode()) <= 4096:
        parser.error("body must contain 1..4096 bytes")
    allowed = [ipaddress.ip_network(value, strict=False) for value in args.allow]
    if any(network.prefixlen == 0 for network in allowed):
        parser.error("allow specific test egress addresses/subnets, not the entire Internet")
    stop = threading.Event()
    for event in (signal.SIGINT, signal.SIGTERM):
        signal.signal(event, lambda *_: stop.set())
    servers = []
    threads = []
    try:
        # Bind everything before serving anything; partial setup is a failure.
        for host in args.bind:
            for kind, port in (("http", args.http_port), ("tcp", args.tcp_port), ("udp", args.udp_port)):
                servers.append(make_server(kind, host, port, allowed, args.body.encode()))
        for server in servers:
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
            threads.append(thread)
            thread.start()
        print("Responder ready: " + str(len(servers)) + " listeners; no request logging.", flush=True)
        stop.wait()
    finally:
        for server in servers[:len(threads)]:
            server.shutdown()
        for server in servers:
            server.server_close()
        for thread in threads:
            thread.join(timeout=2)


if __name__ == "__main__":
    main()
