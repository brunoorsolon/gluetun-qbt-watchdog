#!/usr/bin/env python3
"""Monitoring and opt-in authenticated VPN restart requests; no Docker access."""
import hmac
import json
import os
from pathlib import Path
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def health_snapshot(path, stale_after):
    try:
        timestamp, status, reason, vpn_attempts, container_attempted = Path(path).read_text().split()
        age = time.clock_gettime(time.CLOCK_BOOTTIME) - float(timestamp)
        if age < 0 or age > stale_after:
            return 503, {"status": "unhealthy", "reason": "watchdog_checks_stale"}
        if status not in ("healthy", "recovering", "unrecoverable"):
            raise ValueError("invalid status")
        body = {
            "status": status,
            "reason": reason,
            "vpn_restart_attempts": int(vpn_attempts),
            "container_restart_attempted": bool(int(container_attempted)),
        }
        return (200 if status == "healthy" else 503), body
    except (OSError, ValueError):
        return 503, {"status": "unhealthy", "reason": "watchdog_status_unavailable"}


def make_server(address, path, stale_after, api_key="", state_dir="/state"):
    request_path = Path(state_dir) / "vpn-restart-request"

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def reply(self, status, body):
            data = (json.dumps(body) + "\n").encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_POST(self):
            if self.path != "/vpn/restart" or not api_key:
                self.reply(404, {"error": "not_found"})
                return
            keys = self.headers.get_all("X-API-Key", [])
            if len(keys) != 1 or not hmac.compare_digest(keys[0].encode(), api_key.encode()):
                self.reply(401, {"error": "unauthorized"})
                return
            if self.headers.get("Transfer-Encoding") or self.headers.get_all("Content-Length", ["0"]) != ["0"]:
                self.reply(400, {"error": "body_not_allowed"})
                return
            _, snapshot = health_snapshot(path, stale_after)
            if snapshot["status"] == "unhealthy":
                self.reply(503, {"error": snapshot["reason"]})
                return
            try:
                descriptor = os.open(request_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                os.close(descriptor)
            except FileExistsError:
                self.reply(409, {"status": "already_pending"})
                return
            except OSError:
                self.reply(503, {"error": "restart_queue_unavailable"})
                return
            self.reply(202, {"status": "queued"})

        def do_GET(self):
            if self.path not in ("/healthz", "/readyz"):
                self.send_error(404)
                return
            status, body = health_snapshot(path, stale_after)
            if self.path == "/readyz" and body["status"] == "recovering":
                status = 202
            self.reply(status, body)

        def log_message(self, *args):
            pass  # Kuma polling must not produce a log/notification stream.

    return ThreadingHTTPServer(address, Handler)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    with make_server(
        (os.environ.get("HEALTH_BIND", "0.0.0.0"), int(os.environ.get("HEALTH_PORT", "8081"))),
        sys.argv[1], int(sys.argv[2]), os.environ.get("WATCHDOG_API_KEY", ""), sys.argv[3],
    ) as server:
        server.serve_forever()
