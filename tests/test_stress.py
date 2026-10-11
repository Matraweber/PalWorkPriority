from pathlib import Path
import sys
import tempfile
import unittest
import json
import subprocess
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import stress


def acknowledgement(run="current", request=1, pass_id=100, session="world-1", mode="normal", status="completed", camps=2, dry=None):
    dry = ("true" if mode == "dry" else "false") if dry is None else dry
    return (f"2026-09-11 12:00:00 [PalWorkPriority] PWP_PASS run={run} request={request} "
            f"pass={pass_id} session={session} status={status} mode={mode} camps={camps} dry={dry} pending=0")


class SimulatedGame:
    def __init__(self, reply):
        self.now = 0
        self.reply = reply
        self.queue = []
        self.sent = []

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def send(self, run, request, mode):
        self.sent.append((run, request, mode))
        self.queue.extend(self.reply(run, request, mode))

    def read(self):
        rows, self.queue = self.queue, []
        return rows

    def execute(self, duration=3.2, minimum=3, mode="normal"):
        return stress.run_protocol(
            duration=duration, ack_timeout=2, minimum_passes=minimum,
            tracker=stress.CompletionTracker("current", mode),
            send=self.send, read_lines=self.read, alive=lambda: True,
            clock=self.clock, sleep=self.sleep,
        )


class StressTests(unittest.TestCase):
    def setUp(self):
        native = patch.object(stress.subprocess, "run", side_effect=AssertionError("native commands forbidden in fixtures"))
        native.start()
        self.addCleanup(native.stop)

    def test_final_sleep_process_exit_cannot_pass(self):
        game = SimulatedGame(lambda run, request, mode: [acknowledgement(run=run, request=request, pass_id=request)])
        with self.assertRaisesRegex(stress.StressFailure, "exited|not running"):
            stress.run_protocol(duration=2.5, ack_timeout=2, minimum_passes=3,
                tracker=stress.CompletionTracker("current", "normal"), send=game.send, read_lines=game.read,
                alive=lambda: game.now < 2.5, clock=game.clock, sleep=game.sleep)
        self.assertEqual(len(game.sent), 3)

    def test_final_sleep_error_is_drained_before_success(self):
        game = SimulatedGame(lambda run, request, mode: [acknowledgement(run=run, request=request, pass_id=request)])
        def sleep(seconds):
            game.sleep(seconds)
            if game.now >= 2.5:
                game.queue.append("[PalWorkPriority] ERROR final callback failed")
        with self.assertRaisesRegex(stress.StressFailure, "runtime/mod error"):
            stress.run_protocol(duration=2.5, ack_timeout=2, minimum_passes=3,
                tracker=stress.CompletionTracker("current", "normal"), send=game.send, read_lines=game.read,
                alive=lambda: True, clock=game.clock, sleep=sleep)
        self.assertEqual(len(game.sent), 3)

    def test_actual_dry_must_match_requested_mode(self):
        for mode, actual in (("normal", "true"), ("sweep", "true"), ("dry", "false")):
            with self.subTest(mode=mode, actual=actual):
                tracker = stress.CompletionTracker("current", mode)
                with self.assertRaisesRegex(stress.StressFailure, "dry"):
                    tracker.consume(acknowledgement(mode=mode, dry=actual), 1)
                self.assertEqual(tracker.completed, {})

    def test_missing_or_malformed_actual_dry_is_not_assumed(self):
        for record in (acknowledgement().replace(" dry=false", ""), acknowledgement(dry="unknown"),
                       acknowledgement(dry="False"), acknowledgement(dry="0")):
            with self.subTest(record=record):
                with self.assertRaises(stress.StressFailure):
                    stress.CompletionTracker("current", "normal").consume(record, 1)

    def test_verified_actual_dry_is_retained_for_each_supported_mode(self):
        for mode in ("normal", "sweep", "dry"):
            with self.subTest(mode=mode):
                game = SimulatedGame(lambda run, request, mode: [
                    acknowledgement(run=run, request=request, pass_id=request, mode=mode)])
                report = game.execute(mode=mode)
                self.assertIs(report["actual_dry"], mode == "dry")
                completion = stress.CompletionTracker("current", mode).consume(acknowledgement(mode=mode), 1)
                self.assertIs(completion.actual_dry, mode == "dry")

    def test_process_exit_during_final_drain_cannot_pass(self):
        game = SimulatedGame(lambda run, request, mode: [acknowledgement(run=run, request=request, pass_id=request)])
        still_alive = [True]
        def read():
            rows = game.read()
            if game.now >= 2.5:
                still_alive[0] = False
            return rows
        with self.assertRaisesRegex(stress.StressFailure, "final health check"):
            stress.run_protocol(duration=2.5, ack_timeout=2, minimum_passes=3,
                tracker=stress.CompletionTracker("current", "normal"), send=game.send, read_lines=read,
                alive=lambda: still_alive[0], clock=game.clock, sleep=game.sleep)

    def test_conflicting_ack_in_final_drain_fails_and_identical_replay_is_harmless(self):
        for conflicting in (True, False):
            with self.subTest(conflicting=conflicting):
                game = SimulatedGame(lambda run, request, mode: [acknowledgement(run=run, request=request, pass_id=request)])
                def sleep(seconds):
                    game.sleep(seconds)
                    if game.now >= 2.5:
                        game.queue.append(acknowledgement(request=3, pass_id=999 if conflicting else 3))
                def execute():
                    return stress.run_protocol(duration=2.5, ack_timeout=2, minimum_passes=3,
                        tracker=stress.CompletionTracker("current", "normal"), send=game.send, read_lines=game.read,
                        alive=lambda: True, clock=game.clock, sleep=sleep)
                if conflicting:
                    with self.assertRaisesRegex(stress.StressFailure, "conflicting"):
                        execute()
                else:
                    self.assertEqual(execute()["completed_passes"], 3)

    def test_process_liveness_excludes_foreign_installations_and_launcher_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "installation"
            for is_server in (False, True):
                family = "PalServer" if is_server else "Palworld"
                paths = {"root": str(root), "server": is_server, "process": family + "*"}
                own = {"pid": 10, "path": str(root / "Pal/Binaries/Win64" / (family + "-Win64-Shipping.exe")),
                       "started_ticks": "123456", "alive": True}
                foreign = {**own, "pid": 20, "path": str(Path(directory) / "elsewhere" / Path(own["path"]).name)}
                launcher = {**own, "path": str(root / (family + ".exe"))}
                for rows, expected in (([own, foreign], True), ([foreign], False), ([launcher, foreign], False), ([], False)):
                    with self.subTest(server=is_server, rows=rows):
                        reply = subprocess.CompletedProcess([], 0, json.dumps(rows), "")
                        with patch.object(stress.subprocess, "run", return_value=reply) as native:
                            self.assertIs(stress.process_up(paths), expected)
                        command = native.call_args.args[0][-1]
                        self.assertNotIn("Get-Process -Name", command)
                        self.assertNotIn(family + "*", command)
                        self.assertIn(family + "-Win64-Shipping", command)

    def test_unverifiable_process_ownership_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = {"root": directory, "server": True}
            own = {"pid": 10, "path": str(Path(directory) / "Pal/Binaries/Win64/PalServer-Win64-Shipping.exe"),
                   "started_ticks": "123456", "alive": True}
            cases = ([{**own, "path": None}], [{**own, "path": "relative.exe"}], [{**own, "alive": None}],
                     [{**own, "started_ticks": None}], [{**own, "pid": True}], [own, own])
            for rows in cases:
                with self.subTest(rows=rows), patch.object(stress.subprocess, "run",
                        return_value=subprocess.CompletedProcess([], 0, json.dumps(rows), "")):
                    with self.assertRaises(stress.StressFailure):
                        stress.process_up(paths)
            for output, code in (("not-json", 0), ("{}", 0), ("", 1)):
                with self.subTest(output=output), patch.object(stress.subprocess, "run",
                        return_value=subprocess.CompletedProcess([], code, output, "enumeration denied")):
                    with self.assertRaises(stress.StressFailure):
                        stress.process_up(paths)

    def test_exact_server_cmd_variant_is_allowed_but_foreign_and_client_cmd_are_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "installation"
            cmd = root / "Pal/Binaries/Win64/PalServer-Win64-Shipping-Cmd.exe"
            row = {"pid": 30, "path": str(cmd), "started_ticks": "123456", "alive": True}
            cases = ((True, row, True),
                     (True, {**row, "path": str(Path(directory) / "elsewhere" / cmd.name)}, False),
                     (False, {**row, "path": str(cmd.with_name("Palworld-Win64-Shipping-Cmd.exe"))}, False))
            for is_server, current, expected in cases:
                with self.subTest(server=is_server, path=current["path"]), patch.object(stress.subprocess, "run",
                        return_value=subprocess.CompletedProcess([], 0, json.dumps([current]), "")) as query:
                    self.assertIs(stress.process_up({"root": str(root), "server": is_server}), expected)
                    self.assertNotIn("PalServer*", query.call_args.args[0][-1])

    def test_exact_selection_accepts_windows_path_case_and_ignores_confirmed_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "PalServer-Win64-Shipping.exe"
            row = {"pid": 10, "path": str(executable).upper(), "started_ticks": "123456", "alive": True}
            selected = stress.select_processes([executable], query=lambda _: json.dumps([row, {"path": None, "alive": False}]))
            self.assertEqual(selected, [row])

    def test_nonfinite_timeouts_cannot_wait_forever(self):
        game = SimulatedGame(lambda *_: [])
        with self.assertRaises(ValueError):
            game.execute(duration=float("inf"))

    def test_inert_mod_fails_despite_live_process(self):
        game = SimulatedGame(lambda *_: [])
        with self.assertRaisesRegex(stress.StressFailure, "no completed pass"):
            game.execute()
        self.assertEqual(len(game.sent), 1)

    def test_periodic_ticks_and_command_echoes_do_not_pass(self):
        game = SimulatedGame(lambda *_: ["INFO tick: 2 camp(s), 14 pal(s)", "sent: pwp run", "transport echo returned"])
        with self.assertRaises(stress.StressFailure):
            game.execute()

    def test_only_distinct_command_bound_completions_pass(self):
        game = SimulatedGame(lambda run, request, mode: [
            acknowledgement(run="older-run", request=request, pass_id=999),
            acknowledgement(run=run, request=request, pass_id=100 + request, mode=mode),
        ])
        result = game.execute()
        self.assertEqual(result["completed_passes"], 4)
        self.assertEqual(result["commands_sent"], 4)
        self.assertEqual(result["pass_ids"], [101, 102, 103, 104])
        self.assertIn("frame times not measured", result["evidence"])

    def test_reused_pass_id_fails(self):
        game = SimulatedGame(lambda run, request, mode: [acknowledgement(run=run, request=request, pass_id=100)])
        with self.assertRaisesRegex(stress.StressFailure, "distinct"):
            game.execute()

    def test_session_transition_fails(self):
        game = SimulatedGame(lambda run, request, mode: [
            acknowledgement(run=run, request=request, pass_id=request, session=f"world-{request}")])
        with self.assertRaisesRegex(stress.StressFailure, "session changed"):
            game.execute()

    def test_rejected_empty_wrong_request_and_wrong_mode_fail(self):
        for kwargs in ({"status": "queued"}, {"camps": 0}, {"request": 2}, {"mode": "sweep"}):
            with self.subTest(kwargs=kwargs):
                tracker = stress.CompletionTracker("current", "normal")
                with self.assertRaises(stress.StressFailure):
                    tracker.consume(acknowledgement(**kwargs), 1)

    def test_duplicate_ack_does_not_create_another_pass(self):
        tracker = stress.CompletionTracker("current", "normal")
        self.assertIsNotNone(tracker.consume(acknowledgement(), 1))
        self.assertIsNone(tracker.consume(acknowledgement(), 1))
        self.assertIsNone(tracker.consume(acknowledgement(), 2))
        self.assertEqual(len(tracker.completed), 1)

    def test_too_short_window_cannot_succeed(self):
        game = SimulatedGame(lambda run, request, mode: [acknowledgement(run=run, request=request, pass_id=request)])
        with self.assertRaisesRegex(stress.StressFailure, "need at least"):
            game.execute(duration=0.2)

    def test_new_runtime_errors_fail_even_with_completion(self):
        game = SimulatedGame(lambda run, request, mode: [
            acknowledgement(run=run, request=request, pass_id=request),
            "Ref was not function, removing hook"])
        with self.assertRaisesRegex(stress.StressFailure, "runtime/mod error"):
            game.execute()

    def test_log_tail_excludes_history_waits_for_complete_lines_and_detects_rotation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "priority.log"
            path.write_bytes(b"Ref was not function\nold evidence\n")
            tail = stress.LogTail(path)
            self.assertEqual(tail.read(), [])
            with path.open("ab") as handle:
                handle.write(b"new partial")
            self.assertEqual(tail.read(), [])
            with path.open("ab") as handle:
                handle.write(b" line\r\n")
            self.assertEqual(tail.read(), ["new partial line"])
            path.write_bytes(b"rotated\n")
            with self.assertRaisesRegex(stress.StressFailure, "truncated"):
                tail.read()

    def test_request_write_has_unique_nonce_and_does_not_modify_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            trigger = Path(directory) / "remote.txt"
            with self.assertRaises(stress.StressFailure):
                stress.send_request(trigger, "current", 1, "normal")
            trigger.write_text("old", encoding="utf-8")
            stress.send_request(trigger, "current", 1, "normal")
            self.assertEqual(trigger.read_text(), "current-1\npwp run current 1 normal\n")
            self.assertEqual(list(Path(directory).iterdir()), [trigger])


if __name__ == "__main__":
    unittest.main()
