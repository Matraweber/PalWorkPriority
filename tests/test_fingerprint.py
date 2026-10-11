"""Offline identity tests: no installed files, real processes or game calls."""
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import fingerprint as fp


def put(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data.encode() if isinstance(data, str) else data)
    return path


def mod(root, *, installed=False, version="0.5.0-rc1"):
    put(root / "Info.json", json.dumps({"Version": version}))
    put(root / "Scripts/main.lua", f'local VERSION = "{version}"\nreturn VERSION\n')
    put(root / "Scripts" / ("default_config.lua" if installed else "config.lua"), "return {enabled=true}\n")
    return root


class FingerprintTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = mod(self.root / "source")
        self.game = self.root / "steamapps/common/Palworld"
        self.native = self.game / "Mods/NativeMods/UE4SS"
        self.install = mod(self.native / "Mods/PalWorkPriority", installed=True)
        self.exe = put(self.game / "Pal/Binaries/Win64/Palworld-Win64-Shipping.exe", b"game image")
        self.dll = put(self.native / "UE4SS.dll", b"runtime image")
        self.start = datetime(2026, 9, 11, 12, 0, 0).astimezone().timestamp()
        self.absent = {"state": "observed", "processes": []}
        # Git absence is legitimate; it must not prevent local file fingerprints.
        self.git = mock.patch.object(fp.subprocess, "run", side_effect=FileNotFoundError("git fixture unavailable"))
        self.git.start()
        self.addCleanup(self.git.stop)

    def process(self, **changes):
        return {"pid": 123, "path": str(self.exe), "name": "Palworld-Win64-Shipping",
                "started_unix": self.start, "alive_at_end": True,
                "modules_state": "observed", "ue4ss_modules": [], **changes}

    def report(self, processes=None, **args):
        query = self.absent if processes is None else {"state": "observed", "processes": processes}
        return fp.collect(self.source, self.game, process_query=query, captured_at=self.start + 120, **args)

    def banner(self, time_text, version="0.4.1"):
        return put(self.install / "priority.log", f"{time_text} [PalWorkPriority] Pal Work Priority {version} loaded\n")

    def test_absent_process_with_installed_files_and_recent_banner_is_not_loaded(self):
        self.banner("2026-09-11 12:00:01")
        report = self.report()
        self.assertEqual(report["loaded"]["process_state"], "absent")
        self.assertEqual(report["loaded"]["mod_loaded_state"], "not_running")
        self.assertEqual(report["loaded"]["runtime_state"], "unknown")
        self.assertEqual(report["runtime_files_on_disk"][0]["sha256"], fp.digest(b"runtime image"))
        self.assertEqual(report["log_observations"][0]["loaded_identity_proof"], "none")

    def test_old_log_touched_today_cannot_establish_current_loaded_build(self):
        log = self.banner("2026-08-28 00:32:26")
        os.utime(log, (self.start + 100, self.start + 100))
        report = self.report([self.process()])
        evidence = report["log_observations"][0]
        self.assertEqual(evidence["last_banner_in_bounded_tail"]["classification"], "older_than_current_process")
        self.assertEqual(evidence["last_banner_in_bounded_tail"]["declared_version"], "0.4.1")
        self.assertEqual(evidence["loaded_identity_proof"], "none")
        self.assertEqual(report["loaded"]["mod_loaded_state"], "unknown")

    def test_fresh_and_future_banners_are_unbound_even_with_running_process(self):
        for stamp, category in (("2026-09-11 12:00:01", "after_process_start_but_not_process_bound"),
                                ("2026-09-12 12:00:01", "future_timestamp_unbound"),
                                ("no timestamp", "undated_unbound")):
            with self.subTest(stamp=stamp):
                self.banner(stamp)
                report = self.report([self.process()])
                self.assertEqual(report["loaded"]["mod_loaded_state"], "unknown")
                evidence = report["log_observations"][0]
                self.assertEqual(evidence["loaded_identity_proof"], "none")
                self.assertEqual(evidence["last_banner_in_bounded_tail"]["classification"], category)

    def test_inaccessible_process_query_is_unknown_not_absent(self):
        loaded = fp.loaded_evidence({"state": "unknown", "processes": [], "error": "access denied"}, self.game)
        self.assertEqual(loaded["process_state"], "unknown")
        self.assertEqual(loaded["mod_loaded_state"], "unknown")

    def test_unknown_path_exited_and_unconfirmed_liveness_are_unknown(self):
        for changes in ({"path": None}, {"alive_at_end": False}, {"alive_at_end": None}):
            with self.subTest(changes=changes):
                loaded = self.report([self.process(**changes)])["loaded"]
                self.assertEqual(loaded["process_state"], "unknown")
                self.assertEqual(loaded["mod_loaded_state"], "unknown")

    def test_launcher_only_and_other_install_do_not_prove_target_game_loaded(self):
        launcher = put(self.game / "Palworld.exe", b"launcher")
        loaded = self.report([self.process(path=str(launcher))])["loaded"]
        self.assertEqual(loaded["process_state"], "launcher_only")
        self.assertEqual(loaded["mod_loaded_state"], "unknown")
        other = self.root / "another/Palworld-Win64-Shipping.exe"
        self.assertEqual(self.report([self.process(path=str(other))])["loaded"]["process_state"], "absent")

    def test_mapped_runtime_path_proof_never_promotes_current_disk_hash_to_loaded_hash(self):
        # The process started before a runtime update on disk. Paths match, bytes need not.
        put(self.dll, b"new dll replaced after process start")
        report = self.report([self.process(ue4ss_modules=[{"name": "UE4SS.dll", "path": str(self.dll)}])])
        loaded = report["loaded"]
        self.assertEqual(loaded["process_state"], "running")
        self.assertEqual(loaded["runtime_state"], "mapped_module_observed_hash_unverified")
        runtime = loaded["processes"][0]["mapped_runtime"][0]
        self.assertEqual(runtime["on_disk_identity"]["sha256"], fp.digest(self.dll.read_bytes()))
        self.assertIsNone(runtime["loaded_image_sha256"])
        self.assertEqual(loaded["mod_loaded_state"], "unknown")
        self.assertEqual(loaded["pak_mounted_state"], "unknown")

    def test_failed_module_enumeration_does_not_mean_runtime_absent(self):
        self.assertEqual(self.report([self.process(modules_state="unknown")])["loaded"]["runtime_state"], "unknown")
        self.assertEqual(self.report([self.process()])["loaded"]["runtime_state"], "not_observed_in_current_module_lists")

    def test_duplicate_install_candidates_exclude_workshop_cache(self):
        cache = self.root / "steamapps/workshop/content/1623730"
        mod(cache / fp.WORKSHOP_ID)
        first = self.report()
        self.assertEqual(first["duplicate_install_candidates"], [])
        self.assertEqual(first["workshop_cache"]["state"], "present")
        legacy = mod(self.game / "Pal/Binaries/Win64/ue4ss/Mods/PalWorkPriority", installed=True)
        report = self.report()
        self.assertEqual(set(report["duplicate_install_candidates"]), {str(self.install), str(legacy)})
        self.assertIsNone(report["duplicate_loads_confirmed"])

    def archive(self, kind="workshop", extra=None, omit=()):
        path = self.root / f"candidate-{kind}.zip"
        prefix = "" if kind == "workshop" else fp.MANUAL_ROOT
        payload = {prefix + "Info.json": (self.source / "Info.json").read_bytes(),
                   prefix + "Scripts/main.lua": (self.source / "Scripts/main.lua").read_bytes(),
                   prefix + "Scripts/default_config.lua": (self.source / "Scripts/config.lua").read_bytes(),
                   ("LogicMods/" if kind == "workshop" else "Pal/Content/Paks/LogicMods/") + fp.MOD + ".pak": b"pak fixture"}
        payload.update(extra or {})
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in payload.items():
                if name not in omit:
                    archive.writestr(name, data)
        return path

    def test_both_package_layouts_match_source_and_install_after_config_rename(self):
        for kind in ("manual", "workshop"):
            with self.subTest(kind=kind):
                report = self.report(candidate=self.archive(kind))
                candidate = report["candidate"]
                self.assertEqual(candidate["state"], "present")
                self.assertTrue(candidate["version_consistent"])
                self.assertEqual(candidate["file_set_sha256"], report["source"]["file_set_sha256"])
                self.assertTrue(report["installations"][0]["matches_candidate_code_on_disk"])
                self.assertEqual(candidate["pak"]["sha256"], fp.digest(b"pak fixture"))

    def test_code_mismatch_and_version_drift_are_visible(self):
        put(self.install / "Scripts/main.lua", 'local VERSION = "0.4.1"\n')
        report = self.report()
        self.assertFalse(report["installations"][0]["version_consistent"])
        self.assertFalse(report["installations"][0]["matches_candidate_code_on_disk"])
        self.assertEqual(report["source"]["git"]["state"], "unknown")

    def test_editable_config_and_saves_do_not_change_code_identity(self):
        original = self.report()["installations"][0]["file_set_sha256"]
        for name in ("config.lua", "Scripts/config.lua", "priorities.txt", "caps.txt", "remote.txt"):
            put(self.install / name, "user content must survive")
        report = self.report()
        self.assertEqual(report["installations"][0]["file_set_sha256"], original)
        self.assertNotIn("Scripts/config.lua", report["installations"][0]["files"])

    def test_missing_required_info_or_main_prevents_code_match(self):
        candidate = fp.candidate_identity(self.archive(omit=("Info.json",)), self.source)
        self.assertIsNone(candidate["file_set_sha256"])
        (self.install / "Scripts/main.lua").unlink()
        self.assertIsNone(self.report()["installations"][0]["matches_candidate_code_on_disk"])

    def test_source_and_archive_config_collisions_are_ambiguous(self):
        put(self.source / "Scripts/default_config.lua", "return {}")
        self.assertIsNone(fp.mod_directory(self.source, source=True)["file_set_sha256"])
        candidate = fp.candidate_identity(self.archive(extra={"Scripts/config.lua": b"return {}"}), self.source)
        self.assertEqual(candidate["state"], "ambiguous_config")

    def test_archive_traversal_case_collisions_and_mixed_layout_refused_without_extraction(self):
        for extra, state in (({"../evil.lua": b"evil"}, "invalid_archive_members"),
                             ({"scripts/MAIN.lua": b"collision"}, "invalid_archive_members"),
                             ({fp.MANUAL_ROOT + "Scripts/main.lua": b"other"}, "ambiguous_layout")):
            with self.subTest(extra=extra):
                path = self.archive(extra=extra)
                self.assertEqual(fp.candidate_identity(path, self.source)["state"], state)
                self.assertFalse((self.root / "evil.lua").exists())

    def test_manual_metadata_must_come_from_mod_directory(self):
        path = self.archive("manual", extra={"Info.json": '{"Version":"pretend"}'}, omit=(fp.MANUAL_ROOT + "Info.json",))
        identity = fp.candidate_identity(path, self.source)
        self.assertIsNone(identity["declared_version"])
        self.assertIsNone(identity["file_set_sha256"])

    def test_archive_limits_and_missing_candidate_are_explicit(self):
        with mock.patch.object(fp, "MAX_ARCHIVE_BYTES", 2):
            self.assertEqual(fp.candidate_identity(self.archive(), self.source)["state"], "inspection_limit")
        self.assertEqual(fp.candidate_identity(self.root / "missing.zip", self.source)["state"], "absent")

    def test_log_tail_is_bounded_and_does_not_dump_player_chat(self):
        log = self.banner("2026-08-28 00:00:01")
        with log.open("ab") as handle:
            handle.write(b"private chat message\n" * 20000)
        evidence = self.report()["log_observations"][0]
        self.assertIsNone(evidence["last_banner_in_bounded_tail"])
        self.assertNotIn("private chat", json.dumps(evidence))

    def test_local_steam_build_declaration_must_match_target(self):
        manifest = self.root / "steamapps/appmanifest_1623730.acf"
        put(manifest, '"AppState" { "appid" "1623730" "buildid" "45678" "installdir" "Palworld" }')
        self.assertEqual(self.report()["game_steam_metadata"]["build_id"], "45678")
        put(manifest, '"AppState" { "appid" "999" "buildid" "45678" "installdir" "Other" }')
        self.assertIsNone(self.report()["game_steam_metadata"]["build_id"])

    def test_collect_is_read_only_including_save_and_trigger_files(self):
        for name in ("config.lua", "priorities.txt", "caps.txt", "remote.txt", "priority.log"):
            put(self.install / name, "never change or parse my saved settings")
        before = {str(p): (p.read_bytes(), p.stat().st_mtime_ns) for p in self.root.rglob("*") if p.is_file()}
        with mock.patch.object(fp, "query_processes", side_effect=AssertionError("unexpected real process query")):
            self.report()
        after = {str(p): (p.read_bytes(), p.stat().st_mtime_ns) for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_server_target_queries_server_processes_and_records_server_executable(self):
        server = self.root / "steamapps/common/PalServer"
        runtime = server / "Mods/NativeMods/UE4SS"
        installation = mod(runtime / "Mods/PalWorkPriority", installed=True)
        executable = put(server / "Pal/Binaries/Win64/PalServer-Win64-Shipping.exe", b"server image")
        process = self.process(path=str(executable), name="PalServer-Win64-Shipping")
        with mock.patch.object(fp, "query_processes", return_value={"state": "observed", "processes": [process]}) as query:
            report = fp.collect(self.source, server, server=True)
        query.assert_called_once_with("PalServer*")
        self.assertEqual(report["target"], "server")
        self.assertEqual(report["loaded"]["process_state"], "running")
        self.assertEqual(report["loaded"]["mod_loaded_state"], "unknown")
        self.assertEqual(report["installations"][0]["path"], str(installation))
        self.assertEqual(report["game_executables_on_disk"][1]["sha256"], fp.digest(b"server image"))

    @unittest.skipUnless(os.name == "nt", "Windows process adapter")
    def test_query_failure_malformed_reply_and_empty_success_stay_distinct(self):
        for output, code, expected in (("not json", 0, "unknown"), ("{}", 0, "unknown"),
                                       ('{"state":"observed","processes":[]}', 0, "observed"), ("", 1, "unknown")):
            with self.subTest(output=output, code=code):
                with mock.patch.object(fp.subprocess, "run", return_value=subprocess.CompletedProcess([], code, output, "failed")) as run:
                    self.assertEqual(fp.query_processes("PalServer*")["state"], expected)
                    call = run.call_args
                    self.assertIn("-NonInteractive", call.args[0])
                    self.assertEqual(call.kwargs["creationflags"], subprocess.CREATE_NO_WINDOW)


if __name__ == "__main__":
    unittest.main()
