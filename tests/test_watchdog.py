#!/usr/bin/env python3
"""Exercise the real shell entrypoint with disposable HTTP/Docker/clock fixtures."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "gluetun-qbt-watchdog/gluetun-qbt-watchdog.sh"


def fake_command(command, args):
    path = Path(os.environ["WATCHDOG_TEST_STATE"])
    state = json.loads(path.read_text())
    sample = state["samples"][max(0, state["index"] - 1)]
    output, code = "", 0
    if command == "sleep":
        state.setdefault("pid", os.getppid())
        state["time"] += int(args[0])
    elif command == "cut":
        assert args == ["-d.", "-f1", "/proc/uptime"]
        output = str(state["time"])
    elif command == "docker":
        state["events"].append(["docker", state["time"], args])
        if args[0] == "inspect":
            output = sample.get("health", "running healthy")
            code = 1 if output == "unknown" else 0
        elif args[0] == "restart":
            assert args == ["restart", "--time", "10", "gluetun"], "Never restart other containers"
            code = sample.get("docker_exit", 0)
            output = "permission denied" if code else "gluetun"
        elif args[0] == "logs":
            output = "A temporary password is provided for this session: temporary-test\n"
        else:
            raise AssertionError(args)
    elif command == "curl":
        url = args[-1]
        state["events"].append(["http", state["time"], url, args])
        assert "--max-time" in args and "--connect-timeout" in args
        if "/v1/" in url:
            assert "X-API-Key: test-gluetun" in args
        if url.endswith("/portforward"):
            if state["index"] == len(state["samples"]):
                state["complete"] = True
                path.write_text(json.dumps(state))
                os.kill(state["pid"], signal.SIGTERM)
                return
            sample = state["samples"][state["index"]]
            state["index"] += 1
            if sample.get("manual_reset"):
                (Path(os.environ["STATE_DIR"]) / "reset-request").touch()
            output = sample.get("body", json.dumps({"port": sample.get("port", 0)}))
            output += "|" + str(sample.get("http", 200))
            code = sample.get("curl_exit", 0)
        elif url.endswith("/vpn/status"):
            action = json.loads(args[args.index("-d") + 1])["status"]
            state["events"].append([action, state["time"]])
            code = sample.get(action + "_exit", 0)
        elif url.endswith("/auth/login"):
            assert "Authorization: Bearer test-qbt" not in args
            password = next(arg.split("=", 1)[1] for arg in args if arg.startswith("password="))
            accepted = not sample.get("password_recovery") or state.get("password_updated") or password == "temporary-test"
            status = sample.get("login_status", 200) if accepted else 403
            Path(args[args.index("-o") + 1]).write_text("Ok." if status == 200 else "")
            output = str(status)
        elif "/api/v2/" in url:
            assert "Authorization: Bearer test-qbt" in args or "-b" in args
            if url.endswith("/webapiVersion"):
                output = str(sample.get("qbt_auth_http", 200))
            elif url.endswith("/preferences"):
                output = json.dumps({"listen_port": state["qbt_port"]})
                code = sample.get("qbt_get_exit", 0)
            elif url.endswith("/setPreferences"):
                data = args[args.index("--data-urlencode") + 1]
                prefs = json.loads(data.removeprefix("json="))
                if "web_ui_password" in prefs:
                    assert prefs["web_ui_password"] == "configured-test"
                    state["password_updated"] = True
                else:
                    code = sample.get("qbt_set_exit", 0)
                    if not code and not sample.get("qbt_ignore_set"):
                        state["qbt_port"] = prefs["listen_port"]
                        state["events"].append(["sync", state["time"], state["qbt_port"]])
            else:
                raise AssertionError(url)
        else:
            raise AssertionError(url)
    path.write_text(json.dumps(state))
    print(output, end="")
    sys.exit(code)


class WatchdogTests(unittest.TestCase):
    def run_watchdog(self, samples, root=None, **settings):
        if root is None:
            with tempfile.TemporaryDirectory(prefix="watchdog-test-") as directory:
                return self.run_watchdog(samples, Path(directory), **settings)
        state_file = root / "fixture.json"
        previous = json.loads(state_file.read_text()) if state_file.exists() else {}
        state_file.write_text(json.dumps({
            "time": previous.get("time", 0), "index": 0, "qbt_port": previous.get("qbt_port", 6881),
            "samples": samples, "events": [],
        }))
        for command in ("curl", "docker", "sleep", "cut"):
            launcher = root / command
            launcher.write_text(
                f'#!/bin/sh\nexec "{sys.executable}" "{Path(__file__).resolve()}" --fake {command} "$@"\n'
            )
            launcher.chmod(0o700)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env = {
            "PATH": f"{root}:{Path(sys.executable).parent}:/usr/bin:/bin",
            "WATCHDOG_TEST_STATE": str(state_file), "STATE_DIR": str(root / "state"),
            "HEALTH_STATUS_FILE": str(root / "health"), "HEALTH_BIND": "127.0.0.1", "HEALTH_PORT": str(port),
            "QBT_COOKIE": str(root / "cookies"), "QBT_LOGIN_RESPONSE": str(root / "login-response"),
            "GLUETUN_API_KEY": "test-gluetun", "QBT_API_KEY": "test-qbt",
            **{key: str(value) for key, value in settings.items()},
        }
        process = subprocess.Popen(["sh", str(SCRIPT)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=25)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            self.fail(f"Watchdog hung: {stdout}\n{stderr}")
        self.assertEqual(process.returncode, 143, stdout + stderr)
        state = json.loads(state_file.read_text())
        self.assertTrue(state.get("complete"))
        state["health"] = (root / "health").read_text().split()[1:]
        state["persisted"] = (root / "state/recovery.state").read_text()
        return state, stdout + stderr

    @staticmethod
    def events(state, kind):
        return [event[1:] for event in state["events"] if event[0] == kind]

    def restarts(self, state):
        return [event for event in self.events(state, "docker") if event[1][0] == "restart"]

    def test_port_arrives_during_grace_and_changes_on_next_cycle(self):
        state, _ = self.run_watchdog([{}, {}, {}, {"port": 54128}, {"port": 54129}])
        self.assertEqual(self.events(state, "stopped"), [])
        self.assertEqual(self.events(state, "sync"), [[210, 54128], [272, 54129]])
        self.assertEqual(state["health"][:2], ["healthy", "ports_synced"])

    def test_default_budget_exhausts_once_and_only_restarts_gluetun(self):
        state, log = self.run_watchdog([{}] * 45)
        self.assertEqual(self.events(state, "stopped"), [[330], [1235]])
        self.assertEqual(self.events(state, "running"), [[335], [1240]])
        self.assertEqual(self.restarts(state), [[2140, ["restart", "--time", "10", "gluetun"]]])
        self.assertEqual(log.count("ERROR UNRECOVERABLE:"), 1)
        self.assertEqual(log.count("ERROR"), 1)
        self.assertEqual(state["health"][:2], ["unrecoverable", "port_missing_after_recovery"])
        self.assertEqual(log.split("ERROR UNRECOVERABLE:")[1].count("\n"), 1)

    def test_configured_miss_count_is_an_independent_gate(self):
        state, _ = self.run_watchdog([{}] * 11, PORT_MISS_THRESHOLD=10)
        self.assertEqual(self.events(state, "stopped"), [[570]])

    def test_api_errors_do_not_count_or_erase_missing_history(self):
        state, log = self.run_watchdog(
            [{}, {"http": 401}, {"curl_exit": 28}, {}, {}, {}],
            PORT_MISS_THRESHOLD=4, MISSING_PORT_GRACE=300,
        )
        self.assertEqual(self.events(state, "stopped"), [[330]])
        self.assertIn("HTTP 401", log)
        self.assertIn("timeout", log)
        self.assertNotIn("UNRECOVERABLE", log)

    def test_transient_api_failure_late_in_recovery_does_not_exhaust_budget(self):
        state, log = self.run_watchdog([{}] * 6 + [{"http": 403}] + [{}] * 15)
        self.assertEqual(self.events(state, "stopped"), [[330], [1235]])
        self.assertNotIn("UNRECOVERABLE", log)

    def test_persistent_api_errors_alert_once_without_restarts(self):
        state, log = self.run_watchdog([{"http": 403}] * 12)
        self.assertEqual(self.events(state, "stopped"), [])
        self.assertEqual(self.events(state, "docker"), [])
        self.assertEqual(log.count("ERROR UNRECOVERABLE:"), 1)
        self.assertEqual(state["health"][:2], ["unrecoverable", "gluetun_auth_failed"])

    def test_malformed_and_out_of_range_ports_cannot_trigger_recovery(self):
        bodies = ["", "not json", '{}', '{"port":null}', '{"port":-1}', '{"port":65536}',
                  '{"port":01}', '{"port":"1234"}', '{"port":0} trailing',
                  '{"port":0,"error":"failure"}', '{"port":1,"port":0}',
                  '{"port":true}', '{"port":33061.0}', '{"ports":[33061]}', '[33061]']
        state, _ = self.run_watchdog([{"body": body} for body in bodies])
        self.assertEqual(self.events(state, "stopped"), [])
        self.assertEqual(self.events(state, "sync"), [])
        self.assertEqual(self.events(state, "docker"), [])

    def test_gluetun_ports_array_does_not_block_primary_port_sync(self):
        state, log = self.run_watchdog([
            {"body": '{"port":0,"ports":[]}'},
            {"body": '{"port":33061,"ports":[33061]}'},
            {"body": '{"ports":[33062],"port":33062}'},
        ])
        self.assertEqual(self.events(state, "sync"), [[90, 33061], [152, 33062]])
        self.assertEqual(self.events(state, "stopped"), [])
        self.assertEqual(self.restarts(state), [])
        self.assertEqual(state["health"][:2], ["healthy", "ports_synced"])
        self.assertNotIn("Invalid Gluetun port response", log)

    def test_current_gluetun_response_clears_persisted_terminal_state(self):
        with tempfile.TemporaryDirectory(prefix="watchdog-port-format-") as directory:
            root = Path(directory)
            state, log = self.run_watchdog([{"body": "invalid"}] * 8, root)
            self.assertEqual(state["health"][:2], ["unrecoverable", "gluetun_response_invalid"])
            state, log = self.run_watchdog([{"body": '{"port":33061,"ports":[33061]}'}], root)
            self.assertEqual(state["health"][:2], ["healthy", "ports_synced"])
            self.assertEqual(self.events(state, "stopped"), [])
            self.assertEqual(log.count("INFO RECOVERED:"), 1)
            self.assertNotIn("UNRECOVERABLE", log)

    def test_valid_port_resets_missing_timer_and_count(self):
        state, _ = self.run_watchdog([{}] * 5 + [{"port": 54128}] + [{}] * 6)
        self.assertEqual(self.events(state, "stopped"), [[692]])
        state, _ = self.run_watchdog(
            [{}, {}, {"port": 54128}, {}, {}, {}], PORT_MISS_THRESHOLD=3, MISSING_PORT_GRACE=1,
        )
        self.assertEqual(self.events(state, "stopped"), [[332]])

    def test_recovery_rearms_budget_but_does_not_clear_cooldown(self):
        state, log = self.run_watchdog([{}] * 6 + [{"port": 54128}] + [{}] * 15)
        self.assertEqual(self.events(state, "stopped"), [[330], [1237]])
        self.assertEqual(log.count("INFO RECOVERED:"), 1)

    def test_observed_recovery_has_configurable_non_sliding_deadline(self):
        for health in ("running unhealthy", "running starting", "restarting unhealthy", "unknown"):
            with self.subTest(health=health):
                state, _ = self.run_watchdog([{}] * 5 + [{"health": health}] * 7,
                                             GLUETUN_RECOVERY_GRACE=120)
                self.assertEqual(self.events(state, "stopped"), [[450]])

    def test_failed_restart_calls_are_bounded_and_container_fallback_can_be_disabled(self):
        state, log = self.run_watchdog(
            [{"stopped_exit": 22, "running_exit": 28}] * 15,
            MAX_VPN_RESTARTS=1, GLUETUN_RECOVERY_GRACE=60, RESTART_GLUETUN_CONTAINER="false",
        )
        self.assertEqual(self.events(state, "stopped"), [[330]])
        self.assertEqual(self.events(state, "running"), [[335]])
        self.assertEqual(self.restarts(state), [])
        self.assertIn("stop API call failed", log)
        self.assertIn("start API call failed", log)
        self.assertEqual(log.count("ERROR UNRECOVERABLE:"), 1)

    def test_docker_permission_failure_becomes_one_terminal_alert(self):
        state, log = self.run_watchdog(
            [{"docker_exit": 1}] * 12, MAX_VPN_RESTARTS=1,
            RESTART_COOLDOWN=60, GLUETUN_RECOVERY_GRACE=60,
        )
        self.assertEqual(len(self.restarts(state)), 1)
        self.assertEqual(log.count("ERROR UNRECOVERABLE:"), 1)
        self.assertEqual(state["health"][:2], ["unrecoverable", "docker_permission_denied"])
        self.assertNotIn("permission denied", log)  # Raw Docker stderr must not spam the old Dozzle rule.

    def test_qbt_failures_alert_without_vpn_or_container_restarts(self):
        for failure, reason in (
            ({"qbt_auth_http": 403}, "qbittorrent_auth_failed"),
            ({"qbt_get_exit": 28}, "qbittorrent_preferences_unavailable"),
            ({"qbt_set_exit": 22}, "qbittorrent_port_update_failed"),
            ({"qbt_ignore_set": True}, "qbittorrent_port_mismatch"),
        ):
            with self.subTest(reason=reason):
                state, log = self.run_watchdog([{"port": 54128, **failure}] * 9)
                self.assertEqual(self.events(state, "stopped"), [])
                self.assertEqual(self.restarts(state), [])
                self.assertEqual(state["health"][:2], ["unrecoverable", reason])
                self.assertEqual(log.count("ERROR UNRECOVERABLE:"), 1)
                self.assertNotIn("/auth/login", log)
                self.assertFalse(any("/auth/login" in e[1] for e in self.events(state, "http")))

    def test_latch_and_attempt_budget_survive_watchdog_restart(self):
        with tempfile.TemporaryDirectory(prefix="watchdog-persist-") as directory:
            root = Path(directory)
            settings = dict(MAX_VPN_RESTARTS=1, GLUETUN_RECOVERY_GRACE=60,
                            RESTART_COOLDOWN=60, RESTART_GLUETUN_CONTAINER="false")
            state, log = self.run_watchdog([{}] * 10, root, **settings)
            self.assertEqual(log.count("ERROR UNRECOVERABLE:"), 1)
            state, log = self.run_watchdog([{}] * 8, root, **settings)
            self.assertEqual(self.events(state, "stopped"), [])
            self.assertEqual(log, "")
            self.assertEqual(state["health"][0], "unrecoverable")
            state, log = self.run_watchdog([{"port": 54128}, {}] + [{}] * 7, root, **settings)
            self.assertEqual(log.count("INFO RECOVERED:"), 1)
            self.assertEqual(len(self.events(state, "stopped")), 1)
            self.assertEqual(log.count("ERROR UNRECOVERABLE:"), 1)

    def test_in_progress_attempts_and_cooldown_survive_restart(self):
        with tempfile.TemporaryDirectory(prefix="watchdog-persist-") as directory:
            root = Path(directory)
            state, _ = self.run_watchdog([{}] * 6, root)
            self.assertEqual(len(self.events(state, "stopped")), 1)
            state, _ = self.run_watchdog([{}] * 10, root)
            self.assertEqual(self.events(state, "stopped"), [])
            self.assertEqual(state["health"][2], "1")

    def test_manual_reset_rearms_budget(self):
        state, log = self.run_watchdog([{}] * 9 + [{"manual_reset": True}] + [{}] * 9,
                                       MAX_VPN_RESTARTS=1, GLUETUN_RECOVERY_GRACE=60,
                                       RESTART_COOLDOWN=60, RESTART_GLUETUN_CONTAINER="false")
        self.assertEqual(len(self.events(state, "stopped")), 2)
        self.assertEqual(log.count("ERROR UNRECOVERABLE:"), 2)
        self.assertIn("manually reset", log)

    def test_legacy_password_auth_and_temporary_password_recovery(self):
        for sample in ({"login_status": 200}, {"login_status": 204}, {"password_recovery": True}):
            with self.subTest(sample=sample):
                state, _ = self.run_watchdog([{"port": 54128, **sample}],
                                             QBT_API_KEY="", QBT_PASS="configured-test", QBT_AUTH_MODE="password")
                self.assertEqual(state["health"][0], "healthy")
                self.assertEqual(state["qbt_port"], 54128)
                self.assertEqual(bool(state.get("password_updated")), bool(sample.get("password_recovery")))

    def test_whitespace_and_boundary_ports_sync(self):
        state, _ = self.run_watchdog([{"body": ' \n{ "port" : 1 }\r\n'}, {"body": '{"port":65535}'}])
        self.assertEqual(self.events(state, "sync"), [[30, 1], [92, 65535]])

    def test_host_reboot_preserves_terminal_latch(self):
        with tempfile.TemporaryDirectory(prefix="watchdog-reboot-") as directory:
            root = Path(directory)
            self.run_watchdog([{"http": 401}] * 8, root)
            path = root / "state/recovery.state"
            fields = path.read_text().split()
            fields[1] = "previous-boot-id"
            path.write_text(" ".join(fields) + "\n")
            state, log = self.run_watchdog([{}] * 8, root)
            self.assertEqual(state["health"][0], "unrecoverable")
            self.assertEqual(self.events(state, "stopped"), [])
            self.assertEqual(log, "")

    def test_corrupt_or_unwritable_state_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix="watchdog-state-failure-") as directory:
            root = Path(directory)
            marker = root / "must-not-execute"
            persisted = root / "recovery.state"
            persisted.write_text(f"$(touch {marker})\n")
            env = {"PATH": "/usr/bin:/bin", "STATE_DIR": str(root)}
            result = subprocess.run(["sh", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=2)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            persisted.unlink()
            (root / "recovery.tmp").mkdir()
            result = subprocess.run(["sh", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=2)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Cannot persist recovery state", result.stdout)

    def test_invalid_configuration_fails_before_starting(self):
        for value in ("0", "-1", "abc", "08", "1000000000"):
            with self.subTest(value=value):
                result = subprocess.run(["sh", str(SCRIPT)], capture_output=True, text=True, timeout=2,
                                        env={"PATH": "/usr/bin:/bin", "PORT_MISS_THRESHOLD": value})
                self.assertEqual(result.returncode, 1)
                self.assertIn("FATAL:", result.stdout)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fake":
        fake_command(sys.argv[2], sys.argv[3:])
    else:
        unittest.main()
