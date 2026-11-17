#!/usr/bin/env python3
"""ProxyCommand helper: open a TCP tunnel to HOST:PORT through an HTTP CONNECT proxy.

Usage (as ssh ProxyCommand):
    proxy_connect.py HOST PORT [PROXY]

PROXY is "host:port" or "http://[user:pass@]host:port". If omitted, the value of
HTTPS_PROXY / https_proxy is used. Standard library only.
"""
import base64
import os
import socket
import sys
import threading
from urllib.parse import unquote, urlparse


def parse_proxy(value):
    if "://" not in value:
        value = "http://" + value
    u = urlparse(value)
    if not u.hostname:
        raise SystemExit(f"invalid proxy address: {value!r}")
    return u.hostname, u.port or 3128, unquote(u.username or ""), unquote(u.password or "")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    host, port = sys.argv[1], int(sys.argv[2])
    proxy = sys.argv[3] if len(sys.argv) > 3 else (
        os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy") or ""
    )
    if not proxy:
        raise SystemExit("no proxy given (argument or HTTPS_PROXY)")

    phost, pport, user, password = parse_proxy(proxy)
    sock = socket.create_connection((phost, pport), timeout=30)

    req = f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n"
    if user or password:
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        req += f"Proxy-Authorization: Basic {token}\r\n"
    sock.sendall((req + "\r\n").encode())

    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(1)
        if not chunk:
            raise SystemExit("proxy closed the connection")
        buf += chunk
    status = buf.split(b"\r\n", 1)[0].decode(errors="replace")
    if " 200" not in status:
        raise SystemExit(f"proxy refused CONNECT {host}:{port}: {status}")

    sock.settimeout(None)

    def stdin_to_sock():
        try:
            while True:
                data = sys.stdin.buffer.read1(65536)
                if not data:
                    break
                sock.sendall(data)
        except OSError:
            pass
        try:
            sock.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    threading.Thread(target=stdin_to_sock, daemon=True).start()
    out = sys.stdout.buffer
    try:
        while True:
            data = sock.recv(65536)
            if not data:
                break
            out.write(data)
            out.flush()
    except OSError:
        pass


if __name__ == "__main__":
    main()
