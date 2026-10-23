#!/usr/bin/env python3
"""Read-only monitoring endpoint; it never starts or stops containers."""
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


def make_server(address, path, stale_after):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def do_GET(self):
            if self.path != "/healthz":
                self.send_error(404)
                return
            status, body = health_snapshot(path, stale_after)
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

        def log_message(self, *args):
            pass  # Kuma polling must not produce a log/notification stream.

    return ThreadingHTTPServer(address, Handler)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    with make_server(
        (os.environ.get("HEALTH_BIND", "0.0.0.0"), int(os.environ.get("HEALTH_PORT", "8081"))),
        sys.argv[1], int(sys.argv[2]),
    ) as server:
        server.serve_forever()
