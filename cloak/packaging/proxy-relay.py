#!/usr/bin/env python3
"""Local SOCKS5 (no-auth) -> upstream proxy relay.

Chromium has NO SOCKS5 username/password support: a `--proxy-server=socks5://`
URL can only point at a no-auth proxy. To let one ChatGPT Cloak account use an
*authenticated* SOCKS5/HTTP proxy, this relay listens on 127.0.0.1 as a plain
no-auth SOCKS5 server and bridges every CONNECT to the real (authenticated)
upstream. The browser only ever sees a local no-auth socket; the credentials
live in this process.

TCP CONNECT only. WebRTC UDP is already blocked by the CloakBrowser binary, so no
UDP-associate path is needed. The hostname from the browser is forwarded verbatim
to the upstream (remote DNS) so the real OS resolver is never used for proxied
traffic -- the same guarantee as Firefox's `network.proxy.socks_remote_dns=true`.

Usage:
    proxy-relay.py --listen 127.0.0.1:PORT --upstream URL
    URL = socks5://[user:pass@]host:port | http://[user:pass@]host:port | direct

Bind host is forced to 127.0.0.1 regardless of --listen: this relay is no-auth and
must never be reachable off the loopback interface.
"""
from __future__ import annotations

import argparse
import base64
import select
import socket
import ssl
import sys
import threading
from typing import Optional, TypedDict
from urllib.parse import unquote, urlparse

CONNECT_TIMEOUT = 20.0


class Upstream(TypedDict, total=False):
    kind: str            # "direct" | "socks5" | "http" | "https"
    host: str
    port: int
    user: Optional[str]
    password: Optional[str]


def log(*a: object) -> None:
    print("proxy-relay:", *a, file=sys.stderr, flush=True)


def recvn(sock: socket.socket, n: int) -> bytes:
    """Read exactly n bytes or raise; SOCKS framing needs precise reads."""
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("short read")
        buf += chunk
    return buf


def parse_upstream(url: str) -> Upstream:
    if url == "direct":
        return {"kind": "direct"}
    p = urlparse(url)
    scheme = (p.scheme or "").lower()
    if scheme not in ("socks5", "http", "https"):
        raise ValueError(f"unsupported upstream scheme: {scheme!r}")
    if not p.hostname or not p.port:
        raise ValueError("upstream needs host:port")
    return {
        "kind": scheme,
        "host": p.hostname,
        "port": int(p.port),
        "user": unquote(p.username) if p.username else None,
        "password": unquote(p.password) if p.password else None,
    }


def dial_direct(host: str, port: int) -> socket.socket:
    return socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)


def dial_socks5(up: Upstream, host: str, port: int) -> socket.socket:
    s = socket.create_connection((up["host"], up["port"]), timeout=CONNECT_TIMEOUT)
    try:
        # Greeting: offer user/pass (0x02) when we have creds, else no-auth (0x00).
        s.sendall(b"\x05\x01\x02" if up.get("user") else b"\x05\x01\x00")
        ver, method = recvn(s, 2)
        if ver != 0x05:
            raise ConnectionError("upstream is not SOCKS5")
        if method == 0x02:
            if not up.get("user"):
                raise ConnectionError("upstream demands auth but none configured")
            u = (up.get("user") or "").encode()
            pw = (up.get("password") or "").encode()
            # RFC 1929 username/password auth.
            s.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(pw)]) + pw)
            _, status = recvn(s, 2)
            if status != 0x00:
                raise ConnectionError("upstream auth rejected")
        elif method != 0x00:
            raise ConnectionError(f"upstream chose no acceptable method ({method:#x})")
        # CONNECT with the domain so the upstream resolves it (remote DNS).
        hb = host.encode()
        if len(hb) > 255:
            raise ConnectionError("hostname too long")
        s.sendall(b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb + port.to_bytes(2, "big"))
        reply = recvn(s, 4)
        if reply[1] != 0x00:
            raise ConnectionError(f"upstream CONNECT failed (code {reply[1]})")
        atyp = reply[3]
        if atyp == 0x01:
            recvn(s, 4)
        elif atyp == 0x03:
            recvn(s, recvn(s, 1)[0])
        elif atyp == 0x04:
            recvn(s, 16)
        recvn(s, 2)  # bound port
        return s
    except Exception:
        s.close()
        raise


def dial_http(up: Upstream, host: str, port: int) -> socket.socket:
    s = socket.create_connection((up["host"], up["port"]), timeout=CONNECT_TIMEOUT)
    if up["kind"] == "https":
        ctx = ssl.create_default_context()
        s = ctx.wrap_socket(s, server_hostname=up["host"])
    try:
        req = f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n"
        if up.get("user"):
            tok = base64.b64encode(
                f"{up.get('user')}:{up.get('password') or ''}".encode()
            ).decode()
            req += f"Proxy-Authorization: Basic {tok}\r\n"
        req += "\r\n"
        s.sendall(req.encode())
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = s.recv(4096)
            if not chunk:
                raise ConnectionError("upstream closed during CONNECT")
            data += chunk
        status_line = data.split(b"\r\n", 1)[0]
        if b" 200 " not in status_line:
            raise ConnectionError("upstream CONNECT: " + status_line.decode("latin1"))
        return s
    except Exception:
        s.close()
        raise


def dial_upstream(up: Upstream, host: str, port: int) -> socket.socket:
    kind = up["kind"]
    if kind == "direct":
        return dial_direct(host, port)
    if kind == "socks5":
        return dial_socks5(up, host, port)
    if kind in ("http", "https"):
        return dial_http(up, host, port)
    raise ConnectionError(f"unsupported upstream kind: {kind}")


def pipe(a: socket.socket, b: socket.socket) -> None:
    try:
        while True:
            r, _, _ = select.select([a, b], [], [])
            if a in r:
                d = a.recv(65536)
                if not d:
                    break
                b.sendall(d)
            if b in r:
                d = b.recv(65536)
                if not d:
                    break
                a.sendall(d)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass


def handle(client: socket.socket, up: Upstream) -> None:
    try:
        ver, nmethods = recvn(client, 2)
        if ver != 0x05:
            client.close()
            return
        recvn(client, nmethods)  # advertised methods (ignored; we are no-auth)
        client.sendall(b"\x05\x00")
        head = recvn(client, 4)
        if head[1] != 0x01:  # only CONNECT
            client.sendall(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
            client.close()
            return
        atyp = head[3]
        if atyp == 0x01:
            host = socket.inet_ntoa(recvn(client, 4))
        elif atyp == 0x03:
            host = recvn(client, recvn(client, 1)[0]).decode("idna", "strict")
        elif atyp == 0x04:
            host = socket.inet_ntop(socket.AF_INET6, recvn(client, 16))
        else:
            client.close()
            return
        port = int.from_bytes(recvn(client, 2), "big")
        try:
            remote = dial_upstream(up, host, port)
        except Exception as e:
            log(f"dial fail {host}:{port}: {e}")
            client.sendall(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
            client.close()
            return
        client.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        pipe(client, remote)
    except Exception:
        try:
            client.close()
        except OSError:
            pass


def main() -> int:
    ap = argparse.ArgumentParser(description="Local no-auth SOCKS5 -> upstream relay")
    ap.add_argument("--listen", required=True, help="127.0.0.1:PORT (host forced to loopback)")
    ap.add_argument("--upstream", required=True, help="socks5://.. | http://.. | direct")
    a = ap.parse_args()

    _, _, port_s = a.listen.rpartition(":")
    try:
        port = int(port_s)
    except ValueError:
        log(f"bad --listen {a.listen!r}")
        return 2
    if not (1 <= port <= 65535):
        log(f"port out of range: {port}")
        return 2

    try:
        up = parse_upstream(a.upstream)
    except ValueError as e:
        log(str(e))
        return 2

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))  # loopback only, never externally reachable
    srv.listen(128)
    log(f"listening 127.0.0.1:{port} -> {up['kind']} {up.get('host', '')}")
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client, up), daemon=True).start()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass
