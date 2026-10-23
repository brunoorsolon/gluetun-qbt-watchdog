import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

MODULE_PATH = Path(__file__).resolve().parents[1] / "gluetun-qbt-watchdog/health-server.py"
spec = importlib.util.spec_from_file_location("watchdog_health", MODULE_PATH)
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)


class HealthEndpointTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="watchdog-health-")
        self.path = Path(self.directory.name) / "status"
        self.server = health.make_server(("127.0.0.1", 0), self.path, 180)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/healthz"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.directory.cleanup()

    def publish(self, phase, reason, age=0):
        timestamp = time.clock_gettime(time.CLOCK_BOOTTIME) - age
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(f"{timestamp} {phase} {reason} 2 1\n")
        temporary.replace(self.path)

    def get(self, url=None):
        try:
            response = urllib.request.urlopen(url or self.url, timeout=2)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, response.headers, response.read()

    def test_real_http_status_tracks_recovery_and_success_without_access_logs(self):
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            for phase, expected in (("recovering", 503), ("unrecoverable", 503), ("healthy", 200)):
                self.publish(phase, "test_reason")
                for _ in range(3):
                    status, headers, body = self.get()
                    self.assertEqual(status, expected)
                    self.assertEqual(headers["Cache-Control"], "no-store")
                    self.assertEqual(json.loads(body), {
                        "status": phase, "reason": "test_reason", "vpn_restart_attempts": 2,
                        "container_restart_attempted": True,
                    })
        self.assertEqual(output.getvalue(), "")

    def test_stale_or_future_status_can_never_report_healthy(self):
        for age in (181, -10):
            self.publish("healthy", "ports_synced", age)
            status, _, body = self.get()
            self.assertEqual(status, 503)
            self.assertEqual(json.loads(body)["reason"], "watchdog_checks_stale")

    def test_missing_or_corrupt_status_is_unhealthy(self):
        self.assertEqual(self.get()[0], 503)
        self.path.write_text("broken")
        self.assertEqual(self.get()[0], 503)

    def test_endpoint_has_no_control_routes(self):
        self.assertEqual(self.get(self.url.replace("healthz", "reset"))[0], 404)
        self.publish("unrecoverable", "port_missing_after_recovery")
        before = self.path.read_text()
        self.get()
        self.assertEqual(self.path.read_text(), before)


if __name__ == "__main__":
    unittest.main()
