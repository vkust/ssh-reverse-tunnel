#!/usr/bin/env python3
"""Offline test for scripts/proxy_connect.py.

Starts a local fake HTTP CONNECT proxy and an echo server, then checks that
bytes sent through the helper come back from the echo server. Also checks
the refusal path (proxy answers 403) and Proxy-Authorization handling.
"""
import base64
import os
import socket
import subprocess
import sys
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "scripts", "proxy_connect.py")


def serve(handler):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(5)

    def loop():
        while True:
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            threading.Thread(target=handler, args=(conn,), daemon=True).start()

    threading.Thread(target=loop, daemon=True).start()
    return srv, srv.getsockname()[1]


def read_headers(conn):
    buf = b""
    while b"\r\n\r\n" not in buf:
        c = conn.recv(1)
        if not c:
            break
        buf += c
    return buf.decode(errors="replace")


def echo_server(conn):
    try:
        while True:
            d = conn.recv(4096)
            if not d:
                break
            conn.sendall(d)
    except OSError:
        pass
    finally:
        conn.close()


class ProxyConnectTest(unittest.TestCase):
    def setUp(self):
        self.echo_srv, self.echo_port = serve(echo_server)
        self.seen_headers = []

    def tearDown(self):
        self.echo_srv.close()
        for s in getattr(self, "proxy_servers", []):
            s.close()

    def make_proxy(self, status_line):
        def handler(conn):
            headers = read_headers(conn)
            self.seen_headers.append(headers)
            conn.sendall(status_line.encode() + b"\r\n\r\n")
            if " 200 " in status_line:
                # Relay to the echo server like a real proxy would
                up = socket.create_connection(("127.0.0.1", self.echo_port))
                def pump(a, b):
                    try:
                        while True:
                            d = a.recv(4096)
                            if not d:
                                break
                            b.sendall(d)
                    except OSError:
                        pass
                    finally:
                        try:
                            b.shutdown(socket.SHUT_WR)
                        except OSError:
                            pass
                threading.Thread(target=pump, args=(conn, up), daemon=True).start()
                pump(up, conn)
            conn.close()

        srv, port = serve(handler)
        self.proxy_servers = getattr(self, "proxy_servers", []) + [srv]
        return port

    def run_helper(self, proxy_arg, payload):
        cmd = [sys.executable, HELPER, "127.0.0.1", str(self.echo_port), proxy_arg]
        return subprocess.run(
            cmd, input=payload, capture_output=True, timeout=20
        )

    def test_tunnels_bytes_through_connect(self):
        port = self.make_proxy("HTTP/1.1 200 Connection established")
        res = self.run_helper(f"127.0.0.1:{port}", b"hello-through-proxy")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(res.stdout, b"hello-through-proxy")
        self.assertIn("CONNECT 127.0.0.1:", self.seen_headers[0])

    def test_refused_proxy_exits_nonzero(self):
        port = self.make_proxy("HTTP/1.1 403 Forbidden")
        res = self.run_helper(f"127.0.0.1:{port}", b"x")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn(b"refused", res.stderr)

    def test_basic_auth_header_is_sent(self):
        port = self.make_proxy("HTTP/1.1 200 Connection established")
        res = self.run_helper(f"http://user:p%40ss@127.0.0.1:{port}", b"auth")
        self.assertEqual(res.returncode, 0, res.stderr)
        expected = base64.b64encode(b"user:p@ss").decode()
        self.assertIn(f"Proxy-Authorization: Basic {expected}", self.seen_headers[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
