"""Analyze existing independent frame captures; read-only JSON to stdout.

CSV columns: time_s,frame_ms. time_s is the independent capture clock at frame
END, strictly increasing; frame_ms is positive frame duration, never a Lua region.
Metadata JSON (all these fields required):
  {"schema":1,"capture_id":"run-1","source_kind":"independent_frame_capture",
   "capture_tool":"PresentMon <version>","scene":"base, fixed camera, 120s",
   "machine":"test-pc","game_build":"<identity>","runtime_build":"<identity>",
   "mod_build":"absent or <identity>","profiling":"off",
   "settings":{"resolution":"1920x1080","fps_cap":60},
   "clock":{"name":"qpc-normalized","unit":"s","timestamp":"frame_end"}}

Compare by mod_build (default) or profiling, keeping other metadata equal. Metadata
is a declaration, not verification of the actually loaded builds or scene.

Optional events CSV: time_s,event. Requires a clock-map JSON, never infers that
Lua os.clock is the capture clock:
  {"schema":1,"capture_id":"run-1","event_clock":"lua os.clock",
   "frame_clock":"qpc-normalized","scale":1,"offset_s":-100,
   "uncertainty_ms":2,"valid_frame_interval_s":[0,120],
   "alignment_method":"Measured common markers at the start and end"}
Mapping: frame_time_s = event_time_s * scale + offset_s. It is used only within
the declared validity interval. Proximity to a slow frame does not imply cause.

  python tools/analyze_frames.py after.csv --metadata after.json
  python tools/analyze_frames.py after.csv --metadata after.json --baseline before.csv --baseline-metadata before.json
  python tools/analyze_frames.py after.csv --metadata after.json --events events.csv --clock-map alignment.json

No paths defaults to an explicit missing-capture report. Exit 2 means missing,
invalid or unmatched requested inputs; exit 0 means analyzed, NOT stutter-free.
"""
from __future__ import annotations

import argparse
from bisect import bisect_left
import csv
import hashlib
import io
import json
import math
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
MAX_BYTES = 64 * 1024 * 1024
MAX_ROWS = 1_000_000
MAX_EVENT_DETAILS = 2000
DEFAULT_SPIKES = (16.666667, 33.333333, 50.0, 100.0)
MATCH_FIELDS = ("source_kind", "capture_tool", "scene", "machine", "game_build",
                "runtime_build", "mod_build", "profiling", "settings", "clock")


class InputError(ValueError):
    def __init__(self, state, message):
        super().__init__(message)
        self.state = state


def read_bytes(path, limit=MAX_BYTES):
    if path is None:
        raise InputError("missing", "input path was not supplied")
    path = Path(path)
    try:
        if path.is_symlink():
            raise InputError("invalid", "symlink input is not followed")
        with path.open("rb") as handle:
            before = os.fstat(handle.fileno())
            if before.st_size > limit:
                raise InputError("invalid", "input exceeds inspection limit")
            data = handle.read(limit + 1)
            after = os.fstat(handle.fileno())
        current = path.stat()
        signature = lambda stat: (stat.st_size, stat.st_mtime_ns, stat.st_ino)
        if len(data) > limit or signature(before) != signature(after) or signature(after) != signature(current):
            raise InputError("invalid", "input changed during read or exceeds inspection limit")
        return data
    except FileNotFoundError as exc:
        raise InputError("missing", f"input does not exist: {path}") from exc
    except OSError as exc:
        raise InputError("unreadable", str(exc)) from exc


def identity(path, data):
    return {"path": str(Path(path).absolute()), "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


def read_json(path):
    data = read_bytes(path, 256 * 1024)
    try:
        value = json.loads(data.decode("utf-8-sig"))
        # Also rejects overflowed exponents and non-finite values nested in settings.
        json.dumps(value, allow_nan=False)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise InputError("invalid", "metadata must be finite, valid UTF-8 JSON") from exc
    if not isinstance(value, dict):
        raise InputError("invalid", "metadata must be a JSON object")
    return value, identity(path, data)


def finite(value, name, *, positive=False):
    if isinstance(value, bool):
        raise InputError("invalid", f"{name} must be a finite number")
    try:
        number = float(value)
    except (ValueError, TypeError, OverflowError) as exc:
        raise InputError("invalid", f"{name} must be a finite number") from exc
    if not math.isfinite(number) or (positive and number <= 0):
        raise InputError("invalid", f"{name} must be finite" + (" and positive" if positive else ""))
    return number


def validate_metadata(meta):
    if type(meta.get("schema")) is not int or meta["schema"] != 1 or meta.get("source_kind") != "independent_frame_capture":
        raise InputError("invalid", "requires schema 1 and source_kind independent_frame_capture; mod timings are not frames")
    for key in ("capture_id", "capture_tool", "scene", "machine", "game_build", "runtime_build", "mod_build"):
        if not isinstance(meta.get(key), str) or not meta[key].strip():
            raise InputError("invalid", f"metadata requires {key}")
        if meta[key].strip().lower() in ("unknown", "missing", "unavailable", "n/a", "not measured"):
            raise InputError("invalid", f"metadata {key} is unknown; cannot establish matched conditions")
    if meta.get("profiling") not in ("on", "off"):
        raise InputError("invalid", "profiling must be on or off")
    if not isinstance(meta.get("settings"), dict) or not meta["settings"]:
        raise InputError("invalid", "settings must be a nonempty object")
    clock = meta.get("clock")
    if not isinstance(clock, dict) or clock.get("unit") != "s" or clock.get("timestamp") != "frame_end":
        raise InputError("invalid", "clock requires unit s and timestamp frame_end")
    name = clock.get("name")
    if not isinstance(name, str) or not name.strip() or any(
            cpu in name.lower() for cpu in ("os.clock", "process_cpu", "cpu_time")):
        raise InputError("invalid", "frame clock must name the independent capture clock, not a Lua/CPU timer")


def csv_rows(data, required):
    try:
        reader = csv.DictReader(io.StringIO(data.decode("utf-8-sig"), newline=""), strict=True)
        fields = reader.fieldnames
        if not fields or len(fields) != len(set(fields)) or not set(required) <= set(fields):
            raise InputError("invalid", "CSV requires unique columns: " + ",".join(required))
        for index, row in enumerate(reader, 1):
            if index > MAX_ROWS:
                raise InputError("invalid", "CSV row limit exceeded")
            if None in row or any(value is None for value in row.values()):
                raise InputError("invalid", f"CSV row {index} has an inconsistent column count")
            yield index, row
    except (UnicodeError, csv.Error) as exc:
        raise InputError("invalid", "invalid UTF-8 CSV: " + str(exc)) from exc


def quantile(sorted_values, fraction):
    position = (len(sorted_values) - 1) * fraction
    low = math.floor(position)
    high = math.ceil(position)
    return sorted_values[low] + (sorted_values[high] - sorted_values[low]) * (position - low)


def statistics(frames, thresholds):
    values = sorted(ms for _, ms in frames)
    count = len(values)
    window = finite(frames[-1][0] - frames[0][0], "capture timestamp span")
    duration = finite(sum(ms / 1000 for ms in values), "sum of frame durations")
    mean = finite(sum(ms / count for ms in values), "mean frame duration", positive=True)
    result = {"frame_count": count, "first_time_s": frames[0][0], "last_time_s": frames[-1][0],
              "timestamp_span_s": window, "summed_frame_durations_s": duration,
              "mean_ms": mean, "duration_based_fps": 1000 / mean, "max_ms": values[-1],
              "quantile_method": "linear interpolation at (n-1)*p (R7)",
              "quantiles_ms": {name: quantile(values, fraction) for name, fraction in
                               (("p50", .5), ("p90", .9), ("p95", .95), ("p99", .99), ("p99_9", .999))},
              "spikes": [{"threshold_ms": threshold, "comparison": ">", "count": sum(v > threshold for v in values),
                          "percent": sum(v > threshold for v in values) * 100 / count} for threshold in thresholds],
              "worst_frames": [{"frame_index": i, "time_s": t, "frame_ms": ms}
                               for i, (t, ms) in sorted(enumerate(frames), key=lambda entry: (-entry[1][1], entry[0]))[:10]]}
    finite(result["duration_based_fps"], "duration-based fps")
    return result


def capture(path, metadata_path, thresholds):
    report = {"path": str(Path(path).absolute()) if path else None}
    try:
        data = read_bytes(path)
        report["input"] = identity(path, data)
        try:
            meta, meta_id = read_json(metadata_path)
            validate_metadata(meta)
        except InputError as exc:
            return {**report, "state": exc.state + "_metadata", "error": str(exc)}, []
        report.update(metadata=meta, metadata_input=meta_id)
        frames = []
        for index, row in csv_rows(data, ("time_s", "frame_ms")):
            time_s = finite(row["time_s"], f"row {index} time_s")
            ms = finite(row["frame_ms"], f"row {index} frame_ms", positive=True)
            if frames and time_s <= frames[-1][0]:
                raise InputError("invalid", f"row {index}: time_s must strictly increase")
            frames.append((time_s, ms))
        if not frames:
            raise InputError("missing", "capture contains no frame samples")
        return {**report, "state": "analyzed", "statistics": statistics(frames, thresholds)}, frames
    except InputError as exc:
        return {**report, "state": exc.state, "error": str(exc)}, []


def compare(candidate, baseline, field):
    if candidate.get("state") != "analyzed" or baseline.get("state") != "analyzed":
        return {"state": "missing_or_invalid_capture"}
    a, b = candidate["metadata"], baseline["metadata"]
    differences = [key for key in MATCH_FIELDS if key != field and a.get(key) != b.get(key)]
    if differences:
        return {"state": "unmatched", "differing_control_fields": differences}
    if a["capture_id"] == b["capture_id"] or a[field] == b[field]:
        return {"state": "unmatched", "error": "require distinct capture IDs and a different compared field"}
    left, right = candidate["statistics"], baseline["statistics"]
    if min(left["frame_count"], right["frame_count"]) < 2:
        return {"state": "insufficient_samples"}
    return {"state": "matched_metadata", "compared_field": field,
            "candidate_value": a[field], "baseline_value": b[field],
            "delta_candidate_minus_baseline": {
                "mean_ms": left["mean_ms"] - right["mean_ms"], "max_ms": left["max_ms"] - right["max_ms"],
                "timestamp_span_s": left["timestamp_span_s"] - right["timestamp_span_s"],
                "quantiles_ms": {key: left["quantiles_ms"][key] - right["quantiles_ms"][key] for key in left["quantiles_ms"]},
                "spike_percentage_points": [{"threshold_ms": x["threshold_ms"], "delta": x["percent"] - y["percent"]}
                                            for x, y in zip(left["spikes"], right["spikes"])]},
            "limitation": "Descriptive comparison of declared matched conditions; repeat matched captures before attributing a difference."}


def align_events(events_path, mapping_path, candidate, frames, thresholds):
    if events_path is None:
        return {"state": "missing" if mapping_path else "not_requested"}
    try:
        data = read_bytes(events_path)
        if mapping_path is None:
            return {"state": "missing_clock_mapping", "error": "no implicit alignment, including os.clock"}
        mapping, mapping_id = read_json(mapping_path)
        if candidate.get("state") != "analyzed":
            return {"state": "missing_or_invalid_capture"}
        if (type(mapping.get("schema")) is not int or mapping["schema"] != 1
                or mapping.get("capture_id") != candidate["metadata"]["capture_id"]
                or mapping.get("frame_clock") != candidate["metadata"]["clock"]["name"]):
            raise InputError("invalid", "clock mapping must name this capture ID and frame clock")
        for key in ("event_clock", "alignment_method"):
            if not isinstance(mapping.get(key), str) or not mapping[key].strip():
                raise InputError("invalid", f"clock mapping requires {key}")
        scale = finite(mapping.get("scale"), "clock scale", positive=True)
        offset = finite(mapping.get("offset_s"), "clock offset_s")
        uncertainty = finite(mapping.get("uncertainty_ms"), "clock uncertainty_ms")
        interval = mapping.get("valid_frame_interval_s")
        if not isinstance(interval, list) or len(interval) != 2:
            raise InputError("invalid", "mapping requires valid_frame_interval_s [start,end]")
        start, end = (finite(value, "mapping interval") for value in interval)
        if start >= end or uncertainty < 0:
            raise InputError("invalid", "mapping interval must increase and uncertainty must be nonnegative")
        times = [t for t, _ in frames]
        details, count, outside, near_spike, previous = [], 0, 0, 0, None
        capture_start = finite(times[0] - frames[0][1] / 1000, "capture interval start")
        for index, row in csv_rows(data, ("time_s", "event")):
            event_time = finite(row["time_s"], f"event {index} time_s")
            if previous is not None and event_time < previous:
                raise InputError("invalid", "event times must not decrease")
            previous = event_time
            if not row["event"].strip() or len(row["event"]) > 200:
                raise InputError("invalid", "event label must contain 1-200 characters")
            mapped = finite(event_time * scale + offset, "mapped event timestamp")
            event = {"event": row["event"], "event_time_s": event_time, "mapped_time_s": mapped}
            count += 1
            if not (start <= mapped <= end and capture_start <= mapped <= times[-1]):
                event["state"] = "outside_alignment_or_capture_interval"
                outside += 1
            else:
                at = bisect_left(times, mapped)
                candidates = [i for i in (at - 1, at) if 0 <= i < len(times)]
                nearest = min(candidates, key=lambda i: (abs(times[i] - mapped), i))
                frame_end, frame_ms = frames[nearest]
                delta = finite((mapped - frame_end) * 1000, "event-frame offset")
                spike = frame_ms > thresholds[0]
                near_spike += int(spike and abs(delta) <= uncertainty)
                event.update(state="mapped_declared", nearest_frame_index=nearest,
                             nearest_frame_end_s=frame_end, nearest_frame_ms=frame_ms,
                             event_minus_frame_end_ms=delta, nearest_frame_exceeds_first_threshold=spike)
            if len(details) < MAX_EVENT_DETAILS:
                details.append(event)
        if count == 0:
            return {"state": "missing", "error": "events CSV contains no events"}
        return {"state": "aligned_declared" if outside < count else "no_overlapping_events",
                "events_input": identity(events_path, data),
                "mapping_input": mapping_id, "mapping": mapping, "event_count": count,
                "outside_interval_count": outside, "details": details,
                "details_truncated": count > len(details),
                "events_within_uncertainty_of_nearest_spike_endpoint": near_spike,
                "first_spike_threshold_ms": thresholds[0],
                "limitation": "Declared affine clock mapping, not independently verified. Nearest frame endpoint and temporal proximity do not establish causation."}
    except InputError as exc:
        return {"state": exc.state, "error": str(exc)}


def analyze(path=None, metadata=None, *, baseline=None, baseline_metadata=None,
            compare_by="mod_build", events=None, clock_map=None, thresholds=DEFAULT_SPIKES):
    try:
        thresholds = sorted({finite(value, "spike threshold", positive=True) for value in thresholds})
        if not thresholds or compare_by not in ("mod_build", "profiling"):
            raise InputError("invalid", "supply spike thresholds and compare by mod_build or profiling")
    except InputError as exc:
        return {"schema": 1, "state": exc.state, "error": str(exc)}
    candidate, frames = capture(path, metadata, thresholds)
    report = {"schema": 1, "state": candidate["state"], "candidate": candidate,
              "limits": ["Only supplied independent frame captures are analyzed; mod-region timings are not frame times.",
                         "Builds, settings, capture provenance and clock mapping are declared input metadata, not live verification.",
                         "No capture tool is run; no deployment, game access, network, or stutter-free verdict."]}
    if baseline is not None or baseline_metadata is not None:
        before, _ = capture(baseline, baseline_metadata, thresholds)
        report["baseline"] = before
        report["comparison"] = compare(candidate, before, compare_by)
        if report["comparison"]["state"] != "matched_metadata" and report["state"] == "analyzed":
            report["state"] = "incomplete"
    report["event_alignment"] = align_events(events, clock_map, candidate, frames, thresholds)
    if report["event_alignment"]["state"] not in ("not_requested", "aligned_declared") and report["state"] == "analyzed":
        report["state"] = "incomplete"
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("capture", nargs="?", type=Path)
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--baseline-metadata", type=Path)
    parser.add_argument("--compare-by", choices=("mod_build", "profiling"), default="mod_build")
    parser.add_argument("--events", type=Path)
    parser.add_argument("--clock-map", type=Path)
    parser.add_argument("--spike-ms", type=float, nargs="+", default=DEFAULT_SPIKES)
    args = parser.parse_args(argv)
    report = analyze(args.capture, args.metadata, baseline=args.baseline, baseline_metadata=args.baseline_metadata,
                     compare_by=args.compare_by, events=args.events, clock_map=args.clock_map, thresholds=args.spike_ms)
    print(json.dumps(report, indent=2, sort_keys=True, allow_nan=False))
    return 0 if report["state"] == "analyzed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
