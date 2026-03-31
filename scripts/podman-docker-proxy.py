#!/usr/bin/env python3
"""
podman-docker-proxy.py
Thin proxy between /var/run/docker.sock and the real Podman socket.
Works around Podman 4.x bug: Docker compat API name filter returns []
for the "bridge" network even though it exists.

Usage (run as root):
    python3 podman-docker-proxy.py &

The proxy listens on /var/run/docker.sock and forwards to the real
Podman socket at /run/podman/podman-real.sock.
"""
import http.server
import http.client
import json
import os
import socket
import socketserver
import sys
import urllib.parse

LISTEN_SOCK = "/var/run/docker.sock"
UPSTREAM_SOCK = os.environ.get("UPSTREAM_SOCK", "/run/podman/podman.sock")


class UnixHTTPConnection(http.client.HTTPConnection):
    """HTTP connection over a Unix socket."""
    def __init__(self, sock_path):
        super().__init__("localhost")
        self.sock_path = sock_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.sock_path)


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    """Proxies Docker API requests to Podman, fixing the bridge network bug."""

    def do_request(self):
        # Read request body if present
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else None

        # Forward to upstream Podman socket
        conn = UnixHTTPConnection(UPSTREAM_SOCK)
        headers = {k: v for k, v in self.headers.items() if k.lower() != "host"}
        headers["Host"] = "api.moby.localhost"
        conn.request(self.command, self.path, body=body, headers=headers)
        upstream_resp = conn.getresponse()
        resp_body = upstream_resp.read()

        # Workaround: fix bridge network name filter returning empty
        if self._is_bridge_filter_request() and resp_body.strip() in (b"[]", b"null", b""):
            fixed = self._fetch_bridge_network()
            if fixed:
                resp_body = fixed

        # Send response
        self.send_response_only(upstream_resp.status)
        for header, value in upstream_resp.getheaders():
            if header.lower() in ("transfer-encoding",):
                continue
            if header.lower() == "content-length":
                self.send_header(header, str(len(resp_body)))
                continue
            self.send_header(header, value)
        self.send_header("Content-Length", str(len(resp_body)))
        self.end_headers()
        self.wfile.write(resp_body)
        conn.close()

    def _is_bridge_filter_request(self):
        """Check if this is the broken GET /networks?filters={"name":{"bridge":true}}."""
        if "/networks" not in self.path:
            return False
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        filters_raw = params.get("filters", [None])[0]
        if not filters_raw:
            return False
        try:
            filters = json.loads(filters_raw)
            name_filter = filters.get("name", {})
            return "bridge" in name_filter
        except (json.JSONDecodeError, AttributeError):
            return False

    def _fetch_bridge_network(self):
        """Fetch bridge network via inspect and return as a list."""
        try:
            conn = UnixHTTPConnection(UPSTREAM_SOCK)
            conn.request("GET", "/v1.41/networks/bridge",
                         headers={"Host": "api.moby.localhost"})
            resp = conn.getresponse()
            if resp.status == 200:
                body = resp.read()
                net = json.loads(body)
                return json.dumps([net]).encode()
            conn.close()
        except Exception:
            pass
        return None

    def _safe_request(self):
        try:
            self.do_request()
        except BrokenPipeError:
            pass  # Client disconnected, normal for Docker SDK
        except ConnectionError:
            pass
        except Exception as e:
            if os.environ.get("DEBUG"):
                import traceback
                traceback.print_exc()

    # Handle all HTTP methods
    do_GET = _safe_request
    do_POST = _safe_request
    do_PUT = _safe_request
    do_DELETE = _safe_request
    do_HEAD = _safe_request
    do_PATCH = _safe_request

    def log_message(self, format, *args):
        """Suppress request logging unless DEBUG."""
        if os.environ.get("DEBUG"):
            super().log_message(format, *args)


class UnixSocketServer(socketserver.ThreadingUnixStreamServer):
    """Threaded Unix socket HTTP server."""
    allow_reuse_address = True


def main():
    if not os.path.exists(UPSTREAM_SOCK):
        print(f"ERROR: Upstream socket not found at {UPSTREAM_SOCK}", file=sys.stderr)
        print("Ensure Podman socket is active: systemctl enable --now podman.socket",
              file=sys.stderr)
        sys.exit(1)

    # Remove stale listen socket
    if os.path.exists(LISTEN_SOCK) or os.path.islink(LISTEN_SOCK):
        os.unlink(LISTEN_SOCK)

    print(f"Podman Docker API proxy: {LISTEN_SOCK} -> {UPSTREAM_SOCK}")
    print("Workaround: bridge network name filter fix active")

    server = UnixSocketServer(LISTEN_SOCK, ProxyHandler)
    # Set socket permissions to match original
    os.chmod(LISTEN_SOCK, 0o660)
    try:
        import grp
        gid = grp.getgrnam("podman").gr_gid
        os.chown(LISTEN_SOCK, 0, gid)
    except (KeyError, PermissionError):
        pass

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nProxy stopped.")
        server.shutdown()


if __name__ == "__main__":
    main()
