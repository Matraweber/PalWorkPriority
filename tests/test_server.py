import sys
from pathlib import Path
import tempfile
import unittest
import json
import os
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
with patch.dict(os.environ, {"PWP_SP_WORLD": "isolated-fixture-only"}):
    import server
from stress import LogTail, StressFailure


class ProcessFixture:
    """Observe command construction without executing PowerShell or processes."""
    def __init__(self, rows):
        self.rows = list(rows)
        self.commands = []

    def __call__(self, command):
        self.commands.append(command)
        if "ConvertTo-Json" in command:
            return json.dumps(self.rows)
        # Old helper only asked whether any PalServer* existed.
        return "y" if self.rows else "n"


class ServerTests(unittest.TestCase):
    def setUp(self):
        native = patch.object(server.subprocess, "run", side_effect=AssertionError("native commands forbidden in fixtures"))
        native.start()
        self.addCleanup(native.stop)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        installation = self.root / "server"
        self.p = {"root": str(installation), "exe": str(installation / "PalServer.exe"),
                  "process": "PalServer*", "server": True, "log": str(installation / "priority.log")}
        self.own = {"pid": 41, "path": str(installation / "Pal/Binaries/Win64/PalServer-Win64-Shipping.exe"),
                    "started_ticks": "100001", "alive": True}
        self.foreign = {"pid": 99, "path": str(self.root / "other-server/Pal/Binaries/Win64/PalServer-Win64-Shipping.exe"),
                        "started_ticks": "200002", "alive": True}
        self.config = installation / 'Pal/Saved/Config/WindowsServer/PalWorldSettings.ini'
        self.config.parent.mkdir(parents=True)
        self.config.write_text('[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(RESTAPIEnabled=True,RESTAPIPort=8212,AdminPassword="fixture-secret")')

    def test_stop_requires_graceful_control_and_never_kills(self):
        self.config.write_text('[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(RESTAPIEnabled=False)')
        fixture = ProcessFixture([self.own, self.foreign])
        with patch.object(server, "ps", side_effect=fixture):
            self.assertNotEqual(server.stop(self.p), 0)
        self.assertEqual(fixture.rows, [self.own, self.foreign])
        self.assertFalse(any("Stop-Process" in command for command in fixture.commands))

    def test_start_refuses_missing_shutdown_route_before_launch(self):
        self.config.write_text('[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(RESTAPIEnabled=False)')
        fixture = ProcessFixture([])
        with patch.object(server, 'ps', side_effect=fixture):
            self.assertNotEqual(server.start(self.p), 0)
        self.assertFalse(any('Start-Process' in command for command in fixture.commands))

    def test_stop_delegates_exact_selected_processes(self):
        fixture = ProcessFixture([self.own, self.foreign])
        with patch.object(server, "ps", side_effect=fixture), patch('server_control.graceful_stop') as graceful:
            self.assertEqual(server.stop(self.p), 0)
        self.assertEqual(graceful.call_args.args, (self.p, [self.own]))

    def test_other_installation_does_not_count_as_test_server_running(self):
        with patch.object(server, "ps", side_effect=ProcessFixture([self.foreign])):
            self.assertFalse(server.running(self.p))

    def test_already_running_does_not_claim_readiness_success(self):
        fixture = ProcessFixture([self.own])
        with patch.object(server, "ps", side_effect=fixture), patch.object(server, "wait_ready") as ready:
            self.assertNotEqual(server.start(self.p), 0)
        ready.assert_not_called()
        self.assertFalse(any("Start-Process" in command or "Stop-Process" in command for command in fixture.commands))


    def test_successful_launch_requires_new_marker_and_configured_server_image(self):
        fixture = ProcessFixture([self.foreign])
        log = Path(self.p["log"])
        log.parent.mkdir(parents=True, exist_ok=True)
        historical = "PWP_READY version=0.4.0 session=1 role=authority settings=available\n"
        log.write_text(historical)
        def shell(command):
            if "Start-Process" in command:
                fixture.commands.append(command)
                fixture.rows.append(self.own)
                with log.open("a") as output:
                    output.write("PWP_READY version=0.5.0-rc1 session=2 role=authority settings=available\n")
                return ""
            return fixture(command)
        with patch.object(server, "ps", side_effect=shell):
            self.assertEqual(server.start(self.p), 0)
        self.assertTrue(log.read_text().startswith(historical), "startup truncated history")
        self.assertEqual(fixture.rows, [self.foreign, self.own])
        launch = [command for command in fixture.commands if "Start-Process" in command]
        self.assertEqual(len(launch), 1)
        self.assertIn("-WindowStyle Hidden", launch[0])
        self.assertIn(self.p["exe"], launch[0])

    def test_ready_marker_followed_by_dead_server_or_launcher_only_fails(self):
        for only_launcher in (False, True):
            fixture = ProcessFixture([])
            def shell(command):
                if "Start-Process" in command:
                    if only_launcher:
                        fixture.rows.append({**self.own, "path": self.p["exe"]})
                    return ""
                return fixture(command)
            with self.subTest(launcher=only_launcher), patch.object(server, "ps", side_effect=shell), patch.object(
                    server, "wait_ready", return_value={"version": "0.5.0-rc1", "session": "2"}):
                self.assertNotEqual(server.start(self.p), 0)

    def test_unverifiable_path_never_starts_or_stops_a_process(self):
        for operation in (server.start, server.stop):
            fixture = ProcessFixture([{**self.own, "path": None}])
            with self.subTest(operation=operation.__name__), patch.object(server, "ps", side_effect=fixture):
                self.assertNotEqual(operation(self.p), 0)
            self.assertFalse(any("Start-Process" in command or "Stop-Process" in command for command in fixture.commands))

    def test_launcher_outside_installation_is_refused_before_native_commands(self):
        paths = {**self.p, "exe": str(self.root / "elsewhere/PalServer.exe")}
        with patch.object(server, "ps") as native:
            self.assertNotEqual(server.start(paths), 0)
            self.assertNotEqual(server.stop(paths), 0)
        native.assert_not_called()


    def test_absent_target_with_foreign_server_is_already_stopped_without_control(self):
        fixture = ProcessFixture([self.foreign])
        with patch.object(server, "ps", side_effect=fixture):
            self.assertEqual(server.stop(self.p), 0)
        self.assertEqual(fixture.rows, [self.foreign])
        self.assertFalse(any("Stop-Process" in command for command in fixture.commands))


    def test_boot_banner_and_old_ready_do_not_satisfy_new_launch(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'priority.log'
            path.write_text('PWP_READY version=0.4.1 session=1 role=authority settings=available\n')
            tail = LogTail(path)
            with path.open('a') as f:
                f.write('Pal Work Priority loaded (enabled)\n')
            now = [0.0]
            def sleep(n): now[0] += n
            with self.assertRaises(StressFailure):
                server.wait_ready(tail, lambda: True, timeout=2, clock=lambda: now[0], sleep=sleep)
            with path.open('a') as f:
                f.write('PWP_READY version=0.5.0-rc1 session=2 role=authority settings=available\n')
            self.assertEqual(server.wait_ready(tail, lambda: True)['session'], '2')

    def test_unavailable_settings_cannot_pass(self):
        class Tail:
            def read(self): return ['PWP_READY version=0.5.0-rc1 session=2 role=authority settings=unavailable']
        with self.assertRaises(StressFailure): server.wait_ready(Tail(), lambda: True)

    def test_freshworld_keeps_previous_test_world_and_source(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source = root / 'singleplayer' / 'world-id'
            source.mkdir(parents=True)
            (source / 'Level.sav').write_bytes(b'new')
            base = root / 'server' / 'Pal' / 'Saved' / 'SaveGames' / '0'
            target = base / 'world-id'
            target.mkdir(parents=True)
            (target / 'Level.sav').write_bytes(b'old')
            with patch.object(server, 'SP_WORLD', str(source)), patch.object(server, 'running', return_value=False):
                server.freshworld({'root': str(root / 'server')})
            self.assertEqual((target / 'Level.sav').read_bytes(), b'new')
            self.assertEqual((source / 'Level.sav').read_bytes(), b'new')
            backups = list(base.glob('world-id.backup-*'))
            self.assertEqual(len(backups), 1)
            self.assertEqual((backups[0] / 'Level.sav').read_bytes(), b'old')

    def test_server_world_cannot_be_its_own_source(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source = root / 'Pal' / 'Saved' / 'SaveGames' / '0' / 'world-id'
            source.mkdir(parents=True)
            (source / 'Level.sav').write_bytes(b'old')
            with patch.object(server, 'SP_WORLD', str(source)), patch.object(server, 'running', return_value=False):
                with self.assertRaises(ValueError): server.freshworld({'root': d})


if __name__ == '__main__': unittest.main()
