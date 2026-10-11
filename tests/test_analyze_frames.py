"""Synthetic offline frame captures with independently calculable expectations."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import analyze_frames as af


class FrameAnalysisTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.csv = self.write("after.csv", "time_s,frame_ms\n0.010,10\n0.020,10\n0.050,30\n0.070,20\n")
        self.meta = {
            "schema": 1, "capture_id": "after-1", "source_kind": "independent_frame_capture",
            "capture_tool": "independent fixture", "scene": "fixed camera base", "machine": "test-rig",
            "game_build": "game-hash", "runtime_build": "runtime-hash", "mod_build": "candidate-hash",
            "profiling": "off", "settings": {"resolution": "1920x1080", "fps_cap": 60},
            "clock": {"name": "qpc-normalized", "unit": "s", "timestamp": "frame_end"},
        }
        self.metadata = self.write_json("after.json", self.meta)

    def write(self, name, text):
        path = self.root / name
        path.write_text(text, encoding="utf-8", newline="")
        return path

    def write_json(self, name, value):
        return self.write(name, json.dumps(value))

    def report(self, **args):
        return af.analyze(self.csv, self.metadata, **args)

    def baseline(self, **changes):
        csv = self.write("before.csv", "time_s,frame_ms\n0.020,20\n0.040,20\n0.100,60\n0.140,40\n")
        metadata = self.write_json("before.json", {**self.meta, "capture_id": "before-1", "mod_build": "absent", **changes})
        return {"baseline": csv, "baseline_metadata": metadata}

    def mapping(self, **changes):
        return self.write_json("mapping.json", {
            "schema": 1, "capture_id": "after-1", "event_clock": "lua os.clock",
            "frame_clock": "qpc-normalized", "scale": 1, "offset_s": -5,
            "uncertainty_ms": 2, "valid_frame_interval_s": [0, .070],
            "alignment_method": "fixture common markers at 5s->0s and 5.07s->0.07s", **changes,
        })

    def test_hand_calculated_quantiles_spikes_and_worst_frames(self):
        report = self.report(thresholds=(10, 20, 30))
        self.assertEqual(report["state"], "analyzed")
        stats = report["candidate"]["statistics"]
        self.assertEqual(stats["frame_count"], 4)
        self.assertEqual(stats["mean_ms"], 17.5)
        self.assertAlmostEqual(stats["timestamp_span_s"], .060)
        self.assertAlmostEqual(stats["summed_frame_durations_s"], .070)
        self.assertAlmostEqual(stats["duration_based_fps"], 1000 / 17.5)
        self.assertEqual(stats["quantiles_ms"]["p50"], 15)
        self.assertAlmostEqual(stats["quantiles_ms"]["p95"], 28.5)
        self.assertAlmostEqual(stats["quantiles_ms"]["p99"], 29.7)
        self.assertAlmostEqual(stats["quantiles_ms"]["p99_9"], 29.97)
        self.assertEqual([s["count"] for s in stats["spikes"]], [2, 1, 0])
        self.assertEqual([s["percent"] for s in stats["spikes"]], [50, 25, 0])
        self.assertEqual(stats["worst_frames"][0], {"frame_index": 2, "time_s": .05, "frame_ms": 30})

    def test_missing_capture_is_missing_not_good_performance(self):
        self.assertEqual(af.analyze()["state"], "missing")
        self.assertEqual(af.analyze(self.root / "absent.csv", self.metadata)["state"], "missing")
        self.write("after.csv", "time_s,frame_ms\n")
        report = self.report()
        self.assertEqual(report["state"], "missing")
        self.assertNotIn("statistics", report["candidate"])

    def test_missing_metadata_and_invalid_provenance_never_present_mod_timings_as_frames(self):
        self.assertEqual(af.analyze(self.csv)["state"], "missing_metadata")
        for changes in ({"source_kind": "mod_profiler"}, {"clock": {"name": "os.clock", "unit": "s", "timestamp": "frame_end"}},
                        {"clock": {"name": "process_cpu_time", "unit": "s", "timestamp": "frame_end"}}):
            with self.subTest(changes=changes):
                self.write_json("after.json", {**self.meta, **changes})
                report = self.report()
                self.assertEqual(report["state"], "invalid_metadata")
                self.assertNotIn("statistics", report["candidate"])

    def test_requires_scene_build_setting_and_clock_metadata(self):
        for key in self.meta:
            with self.subTest(missing=key):
                self.write_json("after.json", {k: v for k, v in self.meta.items() if k != key})
                self.assertEqual(self.report()["state"], "invalid_metadata")
        self.write_json("after.json", {**self.meta, "settings": {}})
        self.assertEqual(self.report()["state"], "invalid_metadata")

    def test_nonfinite_metadata_and_invalid_json_are_rejected(self):
        for data in ("[]", "{", json.dumps({**self.meta, "settings": {"fps_cap": float("inf")}}),
                     json.dumps(self.meta).replace('"fps_cap": 60', '"fps_cap": 1e400')):
            with self.subTest(data=data):
                self.write("after.json", data)
                self.assertEqual(self.report()["state"], "invalid_metadata")

    def test_unknown_identities_do_not_count_as_matched_conditions(self):
        for key in ("game_build", "runtime_build", "mod_build", "scene", "machine"):
            with self.subTest(key=key):
                self.write_json("after.json", {**self.meta, key: "unknown"})
                report = self.report(**self.baseline(**{key: "unknown"}))
                self.assertEqual(report["candidate"]["state"], "invalid_metadata")
                self.assertNotEqual(report["comparison"]["state"], "matched_metadata")

    def test_finite_increasing_timestamps_and_positive_frame_durations_required(self):
        for rows in ("0.01,10\n0.01,10", "0.02,10\n0.01,10", "nan,10", "inf,10", "-inf,10",
                     "0.01,NaN", "0.01,Infinity", "0.01,0", "0.01,-1", "0.01,", ",10", "time,10"):
            with self.subTest(rows=rows):
                self.write("after.csv", "time_s,frame_ms\n" + rows + "\n")
                report = self.report()
                self.assertEqual(report["state"], "invalid")
                self.assertNotIn("statistics", report["candidate"])

    def test_derived_numeric_overflow_rejected(self):
        self.write("after.csv", "time_s,frame_ms\n-1e308,10\n1e308,10\n")
        self.assertEqual(self.report()["state"], "invalid")
        self.write("after.csv", "time_s,frame_ms\n0.01,1e-323\n")
        self.assertEqual(self.report()["state"], "invalid")

    def test_normalized_columns_required_and_malformed_rows_fail(self):
        for text in ("timestamp,duration\n1,20\n", "time_s,frame_ms,frame_ms\n1,20,20\n",
                     "time_s,frame_ms\n1\n", "time_s,frame_ms\n1,20,unexpected\n",
                     'time_s,frame_ms\n1,"20\n'):
            with self.subTest(text=text):
                self.write("after.csv", text)
                self.assertEqual(self.report()["state"], "invalid")
        self.write("after.csv", "\ufefftime_s,frame_ms,comment\n0.01,10,normalized\n")
        self.assertEqual(self.report()["state"], "analyzed")

    def test_bounded_rows_and_worst_details(self):
        with mock.patch.object(af, "MAX_ROWS", 3):
            self.assertEqual(self.report()["state"], "invalid")
        self.write("after.csv", "time_s,frame_ms\n" + "".join(f"{i / 10},10\n" for i in range(30)))
        self.assertEqual(len(self.report()["candidate"]["statistics"]["worst_frames"]), 10)

    def test_single_sample_is_described_but_not_enough_for_comparison(self):
        self.write("after.csv", "time_s,frame_ms\n0.01,10\n")
        report = self.report(**self.baseline())
        self.assertEqual(report["candidate"]["statistics"]["quantiles_ms"]["p99"], 10)
        self.assertEqual(report["comparison"]["state"], "insufficient_samples")
        self.assertEqual(report["state"], "incomplete")

    def test_matched_mod_comparison_reports_delta_not_causation(self):
        report = self.report(**self.baseline())
        comparison = report["comparison"]
        self.assertEqual(report["state"], "analyzed")
        self.assertEqual(comparison["state"], "matched_metadata")
        self.assertEqual(comparison["delta_candidate_minus_baseline"]["mean_ms"], -17.5)
        self.assertAlmostEqual(comparison["delta_candidate_minus_baseline"]["quantiles_ms"]["p99"], -29.7)
        self.assertIn("Descriptive", comparison["limitation"])

    def test_different_scenes_builds_settings_or_profiling_cannot_be_matched_by_mod(self):
        for key, value in (("scene", "dungeon"), ("game_build", "new-game"), ("runtime_build", "new-runtime"),
                           ("machine", "other-pc"), ("settings", {"resolution": "1280x800"}),
                           ("profiling", "on"), ("capture_tool", "another tool")):
            with self.subTest(key=key):
                report = self.report(**self.baseline(**{key: value}))
                self.assertEqual(report["comparison"]["state"], "unmatched")
                self.assertIn(key, report["comparison"]["differing_control_fields"])
                self.assertNotIn("delta_candidate_minus_baseline", report["comparison"])

    def test_profile_comparison_requires_same_mod_build(self):
        report = self.report(**self.baseline(mod_build="candidate-hash", profiling="on"), compare_by="profiling")
        self.assertEqual(report["comparison"]["state"], "matched_metadata")
        bad = self.report(**self.baseline(profiling="on"), compare_by="profiling")
        self.assertEqual(bad["comparison"]["state"], "unmatched")

    def test_duplicate_capture_or_unchanged_test_condition_not_accepted(self):
        for changes in ({"capture_id": "after-1"}, {"mod_build": "candidate-hash"}):
            with self.subTest(changes=changes):
                self.assertEqual(self.report(**self.baseline(**changes))["comparison"]["state"], "unmatched")

    def test_missing_baseline_remains_explicit_in_incomplete_comparison(self):
        report = self.report(baseline=self.root / "not-captured.csv", baseline_metadata=self.metadata)
        self.assertEqual(report["baseline"]["state"], "missing")
        self.assertEqual(report["comparison"]["state"], "missing_or_invalid_capture")
        self.assertEqual(report["state"], "incomplete")

    def test_events_are_never_implicitly_aligned_even_when_numbers_look_similar(self):
        events = self.write("events.csv", "time_s,event\n0.05,pass completed\n")
        report = self.report(events=events)
        self.assertEqual(report["event_alignment"]["state"], "missing_clock_mapping")
        self.assertNotIn("details", report["event_alignment"])
        self.assertEqual(report["state"], "incomplete")

    def test_declared_mapping_yields_signed_offsets_and_outside_interval_counts(self):
        events = self.write("events.csv", "time_s,event\n4.9,before capture\n5.044,pass\n5.049,render\n5.2,after capture\n")
        result = self.report(events=events, clock_map=self.mapping())["event_alignment"]
        self.assertEqual(result["state"], "aligned_declared")
        self.assertEqual(result["event_count"], 4)
        self.assertEqual(result["outside_interval_count"], 2)
        self.assertEqual(result["events_within_uncertainty_of_nearest_spike_endpoint"], 1)
        event = result["details"][1]
        self.assertEqual(event["nearest_frame_index"], 2)
        self.assertAlmostEqual(event["event_minus_frame_end_ms"], -6)
        self.assertAlmostEqual(event["mapped_time_s"], .044)
        self.assertIn("do not establish causation", result["limitation"])

    def test_scale_and_validity_interval_are_used_not_just_offset(self):
        events = self.write("events.csv", "time_s,event\n10.01,first\n10.025,second\n")
        result = self.report(events=events, clock_map=self.mapping(scale=2, offset_s=-20, valid_frame_interval_s=[.03, .07]))["event_alignment"]
        self.assertEqual(result["outside_interval_count"], 1)
        self.assertAlmostEqual(result["details"][1]["mapped_time_s"], .05)
        self.assertAlmostEqual(result["details"][1]["event_minus_frame_end_ms"], 0)

    def test_mapping_requires_capture_binding_finite_values_valid_interval_and_method(self):
        events = self.write("events.csv", "time_s,event\n5.01,pass\n")
        for changes in ({"capture_id": "another-run"}, {"frame_clock": "os.clock"}, {"scale": -1},
                        {"scale": 0}, {"offset_s": float("nan")}, {"uncertainty_ms": -1},
                        {"valid_frame_interval_s": [1, 0]}, {"valid_frame_interval_s": []},
                        {"alignment_method": ""}, {"event_clock": ""}, {"offset_s": True}):
            with self.subTest(changes=changes):
                report = self.report(events=events, clock_map=self.mapping(**changes))
                self.assertEqual(report["event_alignment"]["state"], "invalid")
                self.assertEqual(report["state"], "incomplete")

    def test_invalid_events_cannot_create_partial_correlations(self):
        for rows in ("NaN,pass", "5.02,pass\n5.01,earlier", "5.01,", "5.01," + "x" * 201):
            with self.subTest(rows=rows):
                events = self.write("events.csv", "time_s,event\n" + rows + "\n")
                report = self.report(events=events, clock_map=self.mapping())
                self.assertEqual(report["event_alignment"]["state"], "invalid")
                self.assertNotIn("details", report["event_alignment"])

    def test_missing_events_not_silently_successful_and_detail_limits_are_explicit(self):
        report = self.report(events=self.root / "absent.csv", clock_map=self.mapping())
        self.assertEqual(report["event_alignment"]["state"], "missing")
        events = self.write("events.csv", "time_s,event\n5.01,one\n5.01,two\n5.049,three\n")
        with mock.patch.object(af, "MAX_EVENT_DETAILS", 1):
            result = self.report(events=events, clock_map=self.mapping())["event_alignment"]
        self.assertEqual(result["event_count"], 3)
        self.assertEqual(len(result["details"]), 1)
        self.assertTrue(result["details_truncated"])

    def test_no_overlapping_events_is_not_successful_alignment(self):
        events = self.write("events.csv", "time_s,event\n100,far outside recording\n")
        report = self.report(events=events, clock_map=self.mapping())
        self.assertEqual(report["event_alignment"]["state"], "no_overlapping_events")
        self.assertEqual(report["event_alignment"]["outside_interval_count"], 1)
        self.assertEqual(report["state"], "incomplete")

    def test_thresholds_must_be_positive_finite_and_comparison_field_known(self):
        for thresholds in ([], [0], [-1], [float("inf")], [float("nan")]):
            with self.subTest(thresholds=thresholds):
                self.assertEqual(self.report(thresholds=thresholds)["state"], "invalid")
        self.assertEqual(self.report(compare_by="anything")["state"], "invalid")

    def test_read_only_analysis_fingerprints_inputs_without_mutating_them(self):
        events = self.write("events.csv", "time_s,event\n5.049,pass\n")
        mapping = self.mapping()
        baseline = self.baseline()
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.root.iterdir()}
        report = self.report(**baseline, events=events, clock_map=mapping)
        after = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.root.iterdir()}
        self.assertEqual(before, after)
        self.assertEqual(report["candidate"]["input"]["bytes"], len(self.csv.read_bytes()))
        self.assertEqual(len(report["candidate"]["input"]["sha256"]), 64)

    def test_cli_missing_inputs_fail_and_valid_analysis_succeeds_as_json(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(af.main([]), 2)
        self.assertEqual(json.loads(output.getvalue())["state"], "missing")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(af.main([str(self.csv), "--metadata", str(self.metadata)]), 0)
        self.assertEqual(json.loads(output.getvalue())["state"], "analyzed")


if __name__ == "__main__":
    unittest.main()
