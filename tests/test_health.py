from concurrent.futures import ThreadPoolExecutor
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
        self.key = "a" * 64
        self.request_path = Path(self.directory.name) / "vpn-restart-request"
        self.start_server(self.key)

    def start_server(self, key, state_dir=None):
        self.server = health.make_server(("127.0.0.1", 0), self.path, 180, key, state_dir or self.directory.name)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/healthz"

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def tearDown(self):
        self.stop_server()
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
            for phase, strict, attention in (("recovering", 503, 202), ("unrecoverable", 503, 503), ("healthy", 200, 200)):
                self.publish(phase, "test_reason")
                before = self.path.read_text()
                for route, expected in (("healthz", strict), ("readyz", attention)):
                    with self.subTest(phase=phase, route=route):
                        status, headers, body = self.get(self.url.replace("healthz", route))
                        self.assertEqual(status, expected)
                        self.assertEqual(headers["Cache-Control"], "no-store")
                        self.assertEqual(json.loads(body), {
                            "status": phase, "reason": "test_reason", "vpn_restart_attempts": 2,
                            "container_restart_attempted": True,
                        })
                        self.assertEqual(self.path.read_text(), before)
        self.assertEqual(output.getvalue(), "")

    def test_stale_or_future_status_can_never_report_healthy(self):
        for phase in ("healthy", "recovering"):
            for age in (181, -10):
                self.publish(phase, "test_reason", age)
                for route in ("healthz", "readyz"):
                    with self.subTest(phase=phase, age=age, route=route):
                        status, _, body = self.get(self.url.replace("healthz", route))
                        self.assertEqual(status, 503)
                        self.assertEqual(json.loads(body)["reason"], "watchdog_checks_stale")

    def test_missing_or_corrupt_status_is_unhealthy(self):
        timestamp = time.clock_gettime(time.CLOCK_BOOTTIME)
        for content in (None, "broken", f"{timestamp} invalid test_reason 0 0",
                        f"{timestamp} recovering test_reason invalid 0"):
            if content is not None:
                self.path.write_text(content)
            for route in ("healthz", "readyz"):
                with self.subTest(content=content, route=route):
                    status, _, body = self.get(self.url.replace("healthz", route))
                    self.assertEqual(status, 503)
                    self.assertEqual(json.loads(body)["reason"], "watchdog_status_unavailable")

    def post(self, key=None, data=None, **headers):
        if key is not None:
            headers["X-API-Key"] = key
        request = urllib.request.Request(self.url.replace("healthz", "vpn/restart"),
                                         method="POST", data=data, headers=headers)
        return self.get(request)

    def test_restart_requires_correct_key_and_has_no_access_logs(self):
        self.publish("healthy", "ports_synced")
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            for key in (None, "", "wrong", "b" * 64, "é" * 64):
                with self.subTest(key=key):
                    status, _, body = self.post(key)
                    self.assertEqual(status, 401)
                    self.assertEqual(json.loads(body), {"error": "unauthorized"})
                    self.assertFalse(self.request_path.exists())
        self.assertEqual(output.getvalue(), "")

    def test_restart_disabled_without_key(self):
        self.stop_server()
        self.start_server("")
        self.publish("healthy", "ports_synced")
        self.assertEqual(self.post(self.key)[0], 404)
        self.assertFalse(self.request_path.exists())

    def test_concurrent_requests_queue_one_private_marker_without_changing_health(self):
        self.publish("unrecoverable", "port_missing_after_recovery")
        before = self.path.read_text()
        with ThreadPoolExecutor(max_workers=5) as pool:
            responses = list(pool.map(lambda _: self.post(self.key), range(5)))
        self.assertEqual(sorted(response[0] for response in responses), [202, 409, 409, 409, 409])
        self.assertEqual(self.request_path.read_bytes(), b"")
        self.assertEqual(self.request_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.path.read_text(), before)
        self.assertTrue(all(response[1]["Cache-Control"] == "no-store" for response in responses))

    def test_restart_rejects_bodies_and_unavailable_watchdog(self):
        self.publish("healthy", "ports_synced")
        for data, headers in ((b"unexpected", {}), (None, {"Transfer-Encoding": "chunked"})):
            self.assertEqual(self.post(self.key, data, **headers)[0], 400)
            self.assertFalse(self.request_path.exists())
        for age in (181, -10):
            self.publish("healthy", "ports_synced", age=age)
            self.assertEqual(self.post(self.key)[0], 503)
            self.assertFalse(self.request_path.exists())
        self.path.unlink()
        self.assertEqual(self.post(self.key)[0], 503)
        self.assertFalse(self.request_path.exists())

    def test_unavailable_restart_queue_fails_without_success_response(self):
        self.stop_server()
        self.start_server(self.key, Path(self.directory.name) / "missing-directory")
        self.publish("healthy", "ports_synced")
        status, _, body = self.post(self.key)
        self.assertEqual(status, 503)
        self.assertEqual(json.loads(body), {"error": "restart_queue_unavailable"})
        self.assertFalse(self.request_path.exists())

    def test_get_cannot_trigger_restart_or_reset(self):
        self.assertEqual(self.get(self.url.replace("healthz", "vpn/restart"))[0], 404)
        self.assertFalse(self.request_path.exists())
        self.assertEqual(self.get(self.url.replace("healthz", "reset"))[0], 404)
        self.publish("unrecoverable", "port_missing_after_recovery")
        before = self.path.read_text()
        self.get()
        self.assertEqual(self.path.read_text(), before)


if __name__ == "__main__":
    unittest.main()
