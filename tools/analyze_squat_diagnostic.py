#!/usr/bin/env python3
"""Summarize labeled Rise & Grind squat-diagnostic JSONL traces."""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable, Sequence

JsonObject = dict[str, Any]
Vector = tuple[float, float, float]


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description=(
            "Score a labeled squat-diagnostic JSONL trace and print Markdown."
        )
    )
    parser.add_argument("trace", type=Path, help="Path to a JSONL trace.")
    parser.add_argument(
        "--json-output",
        type=Path,
        help="Optionally write the machine-readable summary to this path.",
    )
    return parser.parse_args(argv)


def load_records(path: Path) -> tuple[list[JsonObject], list[str]]:
    """Load valid JSON objects and report malformed lines without stopping."""
    records: list[JsonObject] = []
    warnings: list[str] = []
    with path.open("r", encoding="utf-8") as trace_file:
        for line_number, line in enumerate(trace_file, start=1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                warnings.append(f"line {line_number}: {error.msg}")
                continue
            if isinstance(value, dict):
                records.append(value)
            else:
                warnings.append(f"line {line_number}: record is not an object")
    return records, warnings


def number(value: Any) -> float | None:
    """Return a finite floating-point value when conversion is safe."""
    try:
        converted = float(value)
    except (TypeError, ValueError):
        return None
    return converted if math.isfinite(converted) else None


def vector(value: Any) -> Vector | None:
    """Decode an x/y/z object into a finite vector."""
    if not isinstance(value, dict):
        return None
    components = tuple(number(value.get(axis)) for axis in ("x", "y", "z"))
    if any(component is None for component in components):
        return None
    return components  # type: ignore[return-value]


def magnitude(value: Vector) -> float:
    """Return a vector magnitude."""
    return math.sqrt(sum(component * component for component in value))


def normalized(value: Vector) -> Vector | None:
    """Return a unit vector unless the input is effectively zero."""
    length = magnitude(value)
    if length <= 1e-9:
        return None
    return tuple(component / length for component in value)  # type: ignore[return-value]


def dot(first: Vector, second: Vector) -> float:
    """Return the dot product of two vectors."""
    return sum(a * b for a, b in zip(first, second))


def angle_degrees(first: Vector, second: Vector) -> float | None:
    """Return the smaller three-dimensional angle between two vectors."""
    first_unit = normalized(first)
    second_unit = normalized(second)
    if first_unit is None or second_unit is None:
        return None
    cosine = min(1.0, max(-1.0, dot(first_unit, second_unit)))
    return math.degrees(math.acos(cosine))


def raw_motion(record: JsonObject) -> JsonObject:
    """Return the raw-motion object or an empty object."""
    value = record.get("raw_motion")
    return value if isinstance(value, dict) else {}


def detector(record: JsonObject) -> JsonObject:
    """Return the detector snapshot or an empty object."""
    value = record.get("detector")
    return value if isinstance(value, dict) else {}


def event_details(record: JsonObject) -> JsonObject:
    """Return event details or an empty object."""
    value = record.get("event_details")
    return value if isinstance(value, dict) else {}


def estimate_wall_motion_offset(records: Iterable[JsonObject]) -> float:
    """Estimate the wall-clock minus monotonic-motion timestamp offset."""
    offsets: list[float] = []
    for record in records:
        raw = raw_motion(record)
        motion_time = number(raw.get("motion_timestamp_seconds"))
        wall_time = number(raw.get("callback_wall_time_unix_seconds"))
        if motion_time is not None and wall_time is not None:
            offsets.append(wall_time - motion_time)
    return statistics.median(offsets) if offsets else 0.0


def timeline_time(record: JsonObject, wall_motion_offset: float) -> float | None:
    """Map a sample or event onto the monotonic motion timeline."""
    explicit_marker_time = number(
        event_details(record).get("audio_onset_host_time_seconds")
    )
    if explicit_marker_time is not None:
        return explicit_marker_time
    motion_time = number(raw_motion(record).get("motion_timestamp_seconds"))
    if motion_time is not None:
        return motion_time
    wall_time = number(record.get("wall_time_unix_seconds"))
    if wall_time is None:
        return None
    return wall_time - wall_motion_offset


def percentile(values: Sequence[float], fraction: float) -> float | None:
    """Return a linearly interpolated percentile."""
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * min(1.0, max(0.0, fraction))
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def root_mean_square(values: Sequence[float]) -> float | None:
    """Return the root-mean-square value."""
    if not values:
        return None
    return math.sqrt(sum(value * value for value in values) / len(values))


def extract_samples(
    records: Iterable[JsonObject],
    wall_motion_offset: float,
) -> list[tuple[float, JsonObject]]:
    """Extract timestamped sample records in chronological order."""
    samples: list[tuple[float, JsonObject]] = []
    for record in records:
        if record.get("record_type") != "sample":
            continue
        timestamp = timeline_time(record, wall_motion_offset)
        if timestamp is not None:
            samples.append((timestamp, record))
    return sorted(samples, key=lambda item: item[0])


def extract_events(
    records: Iterable[JsonObject],
    wall_motion_offset: float,
) -> list[tuple[float, JsonObject]]:
    """Extract timestamped event records in chronological order."""
    events: list[tuple[float, JsonObject]] = []
    for record in records:
        if record.get("record_type") != "event":
            continue
        timestamp = timeline_time(record, wall_motion_offset)
        if timestamp is not None:
            events.append((timestamp, record))
    return sorted(events, key=lambda item: item[0])


def collect_stage_runs(
    events: Sequence[tuple[float, JsonObject]],
    trace_end: float,
) -> list[JsonObject]:
    """Build stage-run intervals from explicit start and terminal events."""
    by_run: dict[str, JsonObject] = {}
    terminal_names = {
        "diagnostic_stage_completed": "completed",
        "diagnostic_stage_aborted": "aborted",
        "diagnostic_stage_skipped": "skipped",
    }
    for timestamp, event in events:
        name = event.get("event_name")
        details = event_details(event)
        run_id = str(details.get("stage_run_id", ""))
        if not run_id:
            continue
        if name == "diagnostic_stage_started":
            by_run[run_id] = {
                "run_id": run_id,
                "stage_id": str(details.get("stage_id", "unknown")),
                "expected_motion": str(
                    details.get("expected_motion", "unknown")
                ),
                "partition": str(details.get("partition", "train")),
                "start": timestamp,
                "end": trace_end,
                "status": "incomplete",
            }
        elif name in terminal_names:
            run = by_run.get(run_id)
            if run is None:
                run = {
                    "run_id": run_id,
                    "stage_id": str(details.get("stage_id", "unknown")),
                    "expected_motion": str(
                        details.get("expected_motion", "unknown")
                    ),
                    "partition": str(details.get("partition", "train")),
                    "start": timestamp,
                }
                by_run[run_id] = run
            run["end"] = timestamp
            run["status"] = terminal_names[str(name)]
    return sorted(by_run.values(), key=lambda run: float(run["start"]))


def marker_events(
    events: Sequence[tuple[float, JsonObject]],
) -> list[JsonObject]:
    """Return normalized ground-truth marker events."""
    markers: list[JsonObject] = []
    for timestamp, event in events:
        if event.get("event_name") != "ground_truth_marker":
            continue
        details = event_details(event)
        artifact_window = number(
            details.get("touch_artifact_window_seconds")
        )
        markers.append(
            {
                "time": timestamp,
                "stage_id": str(details.get("stage_id", "unknown")),
                "run_id": str(details.get("stage_run_id", "")),
                "kind": str(details.get("marker_kind", "unknown")),
                "repetition": int(number(details.get("repetition")) or 0),
                "partition": str(details.get("partition", "train")),
                "expected_motion": str(
                    details.get("expected_motion", "unknown")
                ),
                "source": str(details.get("marker_source", "touch")),
                "artifact_window": (
                    artifact_window
                    if artifact_window is not None
                    else 0.2
                ),
            }
        )
    return markers


def stage_run_at_time(
    timestamp: float,
    stage_runs: Sequence[JsonObject],
) -> JsonObject | None:
    """Return the most recently started stage containing a timestamp."""
    candidates = [
        run
        for run in stage_runs
        if float(run["start"]) <= timestamp <= float(run["end"])
    ]
    return max(
        candidates,
        key=lambda run: float(run["start"]),
        default=None,
    )


def detector_events(
    samples: Sequence[tuple[float, JsonObject]],
    stage_runs: Sequence[JsonObject] = (),
) -> list[JsonObject]:
    """Return detector events annotated with their enclosing stage run."""
    results: list[JsonObject] = []
    for timestamp, record in samples:
        snapshot = detector(record)
        event_name = snapshot.get("event")
        if event_name:
            run = stage_run_at_time(timestamp, stage_runs)
            results.append(
                {
                    "time": timestamp,
                    "event": str(event_name),
                    "phase": str(snapshot.get("phase", "unknown")),
                    "rep_count": int(number(snapshot.get("rep_count")) or 0),
                    "stage_id": (
                        str(run["stage_id"]) if run is not None else None
                    ),
                    "run_id": (
                        str(run["run_id"]) if run is not None else None
                    ),
                }
            )
    return results


def within_any_artifact_window(
    timestamp: float,
    markers: Sequence[JsonObject],
) -> bool:
    """Return whether a timestamp is close enough to a marker to be suspect."""
    return any(
        abs(timestamp - float(marker["time"]))
        <= float(marker["artifact_window"])
        for marker in markers
    )


def summarize_sample_interval(
    samples: Sequence[tuple[float, JsonObject]],
    markers: Sequence[JsonObject] = (),
) -> JsonObject:
    """Summarize raw motion and detector behavior over a sample interval."""
    if not samples:
        return {"sample_count": 0}

    usable = [
        item
        for item in samples
        if not within_any_artifact_window(item[0], markers)
    ]
    if len(usable) < 2:
        usable = list(samples)

    axial: list[float] = []
    acceleration_magnitudes: list[float] = []
    horizontal: list[float] = []
    gyro_magnitudes: list[float] = []
    gravity_vectors: list[Vector] = []
    altitudes: list[float] = []
    positions: list[float] = []
    velocities: list[float] = []
    jerks: list[float] = []
    prior_axial: float | None = None
    prior_time: float | None = None

    for timestamp, record in usable:
        raw = raw_motion(record)
        gravity = vector(raw.get("gravity_g"))
        acceleration = vector(raw.get("user_acceleration_g"))
        rotation = vector(raw.get("rotation_rate_radians_per_second"))
        if gravity is not None:
            gravity_vectors.append(gravity)
        if acceleration is not None:
            acceleration_magnitude = magnitude(acceleration)
            acceleration_magnitudes.append(acceleration_magnitude)
            gravity_unit = normalized(gravity) if gravity is not None else None
            if gravity_unit is not None:
                projected = dot(acceleration, gravity_unit)
                axial.append(projected)
                horizontal.append(
                    math.sqrt(
                        max(
                            0.0,
                            acceleration_magnitude * acceleration_magnitude
                            - projected * projected,
                        )
                    )
                )
                if (
                    prior_axial is not None
                    and prior_time is not None
                    and timestamp > prior_time
                ):
                    jerks.append((projected - prior_axial) / (timestamp - prior_time))
                prior_axial = projected
                prior_time = timestamp
        if rotation is not None:
            gyro_magnitudes.append(magnitude(rotation))
        altitude = number(raw.get("relative_altitude_meters"))
        if altitude is not None:
            altitudes.append(altitude)
        snapshot = detector(record)
        position = number(snapshot.get("normalized_vertical_position"))
        velocity = number(snapshot.get("vertical_velocity_meters_per_second"))
        if position is not None:
            positions.append(position)
        if velocity is not None:
            velocities.append(velocity)

    orientation_path = 0.0
    orientation_angles: list[float] = []
    if gravity_vectors:
        initial_gravity = gravity_vectors[0]
        for current in gravity_vectors:
            angle = angle_degrees(initial_gravity, current)
            if angle is not None:
                orientation_angles.append(angle)
        for first, second in zip(gravity_vectors, gravity_vectors[1:]):
            angle = angle_degrees(first, second)
            if angle is not None:
                orientation_path += angle

    timestamps = [item[0] for item in samples]
    intervals = [
        second - first
        for first, second in zip(timestamps, timestamps[1:])
        if second > first
    ]
    events = Counter(
        str(detector(record).get("event"))
        for _, record in samples
        if detector(record).get("event")
    )
    duration = max(0.0, timestamps[-1] - timestamps[0])
    median_interval = statistics.median(intervals) if intervals else None

    return {
        "sample_count": len(samples),
        "marker_artifact_samples_excluded": len(samples) - len(usable),
        "duration_seconds": duration,
        "sample_rate_hz": (
            (len(samples) - 1) / duration if duration > 0 else None
        ),
        "median_interval_seconds": median_interval,
        "maximum_interval_seconds": max(intervals) if intervals else None,
        "axial_acceleration_rms_g": root_mean_square(axial),
        "axial_acceleration_p95_abs_g": percentile(
            [abs(value) for value in axial], 0.95
        ),
        "acceleration_rms_g": root_mean_square(acceleration_magnitudes),
        "acceleration_peak_g": max(acceleration_magnitudes, default=None),
        "horizontal_acceleration_rms_g": root_mean_square(horizontal),
        "gyro_rms_radians_per_second": root_mean_square(gyro_magnitudes),
        "gyro_peak_radians_per_second": max(gyro_magnitudes, default=None),
        "jerk_p95_abs_g_per_second": percentile(
            [abs(value) for value in jerks], 0.95
        ),
        "gravity_tilt_excursion_degrees": max(
            orientation_angles, default=None
        ),
        "gravity_orientation_path_degrees": orientation_path,
        "relative_altitude_range_meters": (
            max(altitudes) - min(altitudes) if altitudes else None
        ),
        "detector_position_range": (
            max(positions) - min(positions) if positions else None
        ),
        "detector_velocity_peak_abs_meters_per_second": max(
            (abs(value) for value in velocities), default=None
        ),
        "detector_events": dict(events),
    }


def samples_between(
    samples: Sequence[tuple[float, JsonObject]],
    start: float,
    end: float,
) -> list[tuple[float, JsonObject]]:
    """Return samples whose timestamps fall inside an inclusive interval."""
    return [item for item in samples if start <= item[0] <= end]


def summarize_stages(
    stage_runs: Sequence[JsonObject],
    samples: Sequence[tuple[float, JsonObject]],
    markers: Sequence[JsonObject],
) -> list[JsonObject]:
    """Attach signal and detector summaries to each labeled stage run."""
    summaries: list[JsonObject] = []
    for run in stage_runs:
        run_markers = [
            marker for marker in markers if marker["run_id"] == run["run_id"]
        ]
        interval = samples_between(
            samples, float(run["start"]), float(run["end"])
        )
        summary = dict(run)
        summary["marker_count"] = len(run_markers)
        if not samples or float(run["start"]) > samples[-1][0]:
            summary["capture_status"] = "missing"
        elif float(run["end"]) > samples[-1][0]:
            summary["capture_status"] = "partial"
        else:
            summary["capture_status"] = "complete"
        summary["metrics"] = summarize_sample_interval(interval, run_markers)
        summaries.append(summary)
    return summaries


def summarize_marker_pairs(
    markers: Sequence[JsonObject],
    samples: Sequence[tuple[float, JsonObject]],
) -> list[JsonObject]:
    """Summarize consecutive labeled half-cycles within each stage run."""
    by_run: dict[str, list[JsonObject]] = defaultdict(list)
    for marker in markers:
        by_run[str(marker["run_id"])].append(marker)

    results: list[JsonObject] = []
    for run_markers in by_run.values():
        ordered = sorted(run_markers, key=lambda marker: float(marker["time"]))
        for first, second in zip(ordered, ordered[1:]):
            start = float(first["time"])
            end = float(second["time"])
            if end <= start:
                continue
            interval_markers = [first, second]
            results.append(
                {
                    "stage_id": first["stage_id"],
                    "run_id": first["run_id"],
                    "from": first["kind"],
                    "to": second["kind"],
                    "from_repetition": first["repetition"],
                    "to_repetition": second["repetition"],
                    "duration_seconds": end - start,
                    "partition": first["partition"],
                    "metrics": summarize_sample_interval(
                        samples_between(samples, start, end),
                        interval_markers,
                    ),
                }
            )
    return results


def align_detector_to_markers(
    markers: Sequence[JsonObject],
    detections: Sequence[JsonObject],
    maximum_offset_seconds: float = 1.5,
) -> list[JsonObject]:
    """Match endpoints one-to-one to detector events from the same stage run."""
    expected_detector_event = {
        "bottom": "bottom_reached",
        "top": "rep_counted",
    }
    results: list[JsonObject] = []
    markers_by_run: dict[str, list[JsonObject]] = defaultdict(list)
    for marker in markers:
        if str(marker["kind"]) in expected_detector_event:
            markers_by_run[str(marker["run_id"])].append(marker)

    detections_by_run: dict[str, list[JsonObject]] = defaultdict(list)
    for detection in detections:
        run_id = detection.get("run_id")
        if run_id:
            detections_by_run[str(run_id)].append(detection)

    for run_id, run_markers in markers_by_run.items():
        available = sorted(
            detections_by_run.get(run_id, []),
            key=lambda detection: float(detection["time"]),
        )
        for marker in sorted(
            run_markers,
            key=lambda candidate: float(candidate["time"]),
        ):
            expected = expected_detector_event[str(marker["kind"])]
            candidate_indexes = [
                index
                for index, detection in enumerate(available)
                if detection["event"] == expected
            ]
            nearest_index = min(
                candidate_indexes,
                key=lambda index: abs(
                    float(available[index]["time"])
                    - float(marker["time"])
                ),
                default=None,
            )
            nearest = (
                available[nearest_index]
                if nearest_index is not None
                else None
            )
            offset = (
                float(nearest["time"]) - float(marker["time"])
                if nearest is not None
                else None
            )
            is_matched = (
                offset is not None
                and abs(offset) <= maximum_offset_seconds
            )
            if is_matched and nearest_index is not None:
                available.pop(nearest_index)
            results.append(
                {
                    "stage_id": marker["stage_id"],
                    "run_id": marker["run_id"],
                    "partition": marker["partition"],
                    "expected_motion": marker["expected_motion"],
                    "repetition": marker["repetition"],
                    "marker_kind": marker["kind"],
                    "marker_time": marker["time"],
                    "expected_detector_event": expected,
                    "detection_time": (
                        nearest["time"] if is_matched else None
                    ),
                    "detector_rep_count": (
                        nearest["rep_count"] if is_matched else None
                    ),
                    "offset_seconds": offset if is_matched else None,
                    "matched": is_matched,
                }
            )
    return results


def summarize_complete_reps(
    markers: Sequence[JsonObject],
    alignments: Sequence[JsonObject],
) -> list[JsonObject]:
    """Report full reps only when both endpoints form one coherent cycle."""
    grouped_markers: dict[
        tuple[str, int], dict[str, JsonObject]
    ] = defaultdict(dict)
    for marker in markers:
        if not str(marker.get("expected_motion", "")).startswith(
            "full_squat"
        ):
            continue
        kind = str(marker.get("kind", ""))
        if kind not in {"bottom", "top"}:
            continue
        key = (str(marker["run_id"]), int(marker["repetition"]))
        grouped_markers[key][kind] = marker

    grouped_alignments: dict[
        tuple[str, int], dict[str, JsonObject]
    ] = defaultdict(dict)
    for alignment in alignments:
        key = (
            str(alignment["run_id"]),
            int(alignment["repetition"]),
        )
        grouped_alignments[key][str(alignment["marker_kind"])] = alignment

    results: list[JsonObject] = []
    for key, endpoints in grouped_markers.items():
        if "bottom" not in endpoints or "top" not in endpoints:
            continue
        bottom_marker = endpoints["bottom"]
        top_marker = endpoints["top"]
        if float(top_marker["time"]) <= float(bottom_marker["time"]):
            continue
        matched = grouped_alignments.get(key, {})
        bottom_alignment = matched.get("bottom", {})
        top_alignment = matched.get("top", {})
        bottom_detection_time = number(
            bottom_alignment.get("detection_time")
        )
        top_detection_time = number(top_alignment.get("detection_time"))
        bottom_rep_count = number(
            bottom_alignment.get("detector_rep_count")
        )
        top_rep_count = number(top_alignment.get("detector_rep_count"))
        events_in_order = (
            bottom_detection_time is not None
            and top_detection_time is not None
            and bottom_detection_time < top_detection_time
        )
        rep_count_incremented = (
            bottom_rep_count is not None
            and top_rep_count is not None
            and int(top_rep_count) == int(bottom_rep_count) + 1
        )
        bottom_matched = bool(bottom_alignment.get("matched"))
        top_matched = bool(top_alignment.get("matched"))
        results.append(
            {
                "stage_id": bottom_marker["stage_id"],
                "run_id": key[0],
                "partition": bottom_marker["partition"],
                "expected_motion": bottom_marker["expected_motion"],
                "repetition": key[1],
                "duration_seconds": (
                    float(top_marker["time"])
                    - float(bottom_marker["time"])
                ),
                "bottom_matched": bottom_matched,
                "top_matched": top_matched,
                "bottom_offset_seconds": bottom_alignment.get(
                    "offset_seconds"
                ),
                "top_offset_seconds": top_alignment.get(
                    "offset_seconds"
                ),
                "detector_events_in_order": events_in_order,
                "detector_rep_count_incremented": rep_count_incremented,
                "matched": (
                    bottom_matched
                    and top_matched
                    and events_in_order
                    and rep_count_incremented
                ),
            }
        )
    return sorted(
        results,
        key=lambda result: (
            str(result["stage_id"]),
            int(result["repetition"]),
        ),
    )


def trace_quality(
    samples: Sequence[tuple[float, JsonObject]],
) -> JsonObject:
    """Summarize sampling continuity for the entire trace."""
    if len(samples) < 2:
        return {"sample_count": len(samples)}
    intervals = [
        second[0] - first[0]
        for first, second in zip(samples, samples[1:])
        if second[0] > first[0]
    ]
    median_interval = statistics.median(intervals)
    gap_threshold = max(0.04, median_interval * 2.5)
    return {
        "sample_count": len(samples),
        "duration_seconds": samples[-1][0] - samples[0][0],
        "sample_rate_hz": (
            (len(samples) - 1) / (samples[-1][0] - samples[0][0])
            if samples[-1][0] > samples[0][0]
            else None
        ),
        "median_interval_seconds": median_interval,
        "maximum_interval_seconds": max(intervals),
        "gap_threshold_seconds": gap_threshold,
        "gap_count": sum(interval > gap_threshold for interval in intervals),
    }


def build_summary(records: Sequence[JsonObject]) -> JsonObject:
    """Build a machine-readable diagnostic summary."""
    wall_motion_offset = estimate_wall_motion_offset(records)
    samples = extract_samples(records, wall_motion_offset)
    events = extract_events(records, wall_motion_offset)
    markers = marker_events(events)
    captured_markers = [
        marker
        for marker in markers
        if samples and samples[0][0] <= float(marker["time"]) <= samples[-1][0]
    ]
    trace_end = samples[-1][0] if samples else 0.0
    stages = collect_stage_runs(events, trace_end)
    detections = detector_events(samples, stages)
    completed_run_ids = {
        str(stage["run_id"])
        for stage in stages
        if stage.get("status") == "completed"
    }
    completed_markers = [
        marker
        for marker in captured_markers
        if str(marker["run_id"]) in completed_run_ids
    ]
    full_squat_markers = [
        marker
        for marker in completed_markers
        if str(marker.get("expected_motion", "")).startswith("full_squat")
        and marker.get("kind") in {"bottom", "top"}
    ]
    marker_alignment = align_detector_to_markers(
        full_squat_markers,
        detections,
    )
    session_started = next(
        (
            event
            for _, event in events
            if event.get("event_name") == "session_started"
        ),
        {},
    )
    schemas = sorted(
        {
            int(number(record.get("schema_version")) or 0)
            for record in records
        }
    )
    return {
        "session_id": session_started.get("session_id"),
        "schema_versions": schemas,
        "session_details": event_details(session_started),
        "quality": trace_quality(samples),
        "event_counts": dict(
            Counter(
                str(record.get("event_name"))
                for _, record in events
                if record.get("event_name")
            )
        ),
        "detector_event_counts": dict(
            Counter(str(event["event"]) for event in detections)
        ),
        "marker_count": len(markers),
        "captured_marker_count": len(captured_markers),
        "completed_marker_count": len(completed_markers),
        "sample_limit_reached": any(
            event.get("event_name") == "sample_limit_reached"
            for _, event in events
        ),
        "unscoped_detector_event_count": sum(
            detection.get("run_id") is None for detection in detections
        ),
        "stage_summaries": summarize_stages(
            stages, samples, markers
        ),
        "half_cycle_summaries": summarize_marker_pairs(
            captured_markers,
            samples,
        ),
        "marker_alignment": marker_alignment,
        "complete_rep_alignment": summarize_complete_reps(
            full_squat_markers,
            marker_alignment,
        ),
    }


def format_number(value: Any, digits: int = 2) -> str:
    """Format a numeric value for a compact Markdown table."""
    converted = number(value)
    return "—" if converted is None else f"{converted:.{digits}f}"


def detector_event_count(metrics: JsonObject, event_name: str) -> int:
    """Return a detector-event count from a stage metrics object."""
    events = metrics.get("detector_events")
    if not isinstance(events, dict):
        return 0
    return int(number(events.get(event_name)) or 0)


def render_markdown(summary: JsonObject, warnings: Sequence[str]) -> str:
    """Render the diagnostic summary as concise Markdown."""
    quality = summary.get("quality", {})
    if not isinstance(quality, dict):
        quality = {}
    lines = [
        "# Squat diagnostic analysis",
        "",
        f"- Session: `{summary.get('session_id') or 'unknown'}`",
        f"- Schema: {', '.join(map(str, summary.get('schema_versions', [])))}",
        (
            f"- Samples: {quality.get('sample_count', 0)} over "
            f"{format_number(quality.get('duration_seconds'))} s at "
            f"{format_number(quality.get('sample_rate_hz'))} Hz"
        ),
        (
            f"- Sampling gaps: {quality.get('gap_count', 0)} "
            f"(maximum {format_number(quality.get('maximum_interval_seconds'), 3)} s)"
        ),
        f"- Ground-truth markers: {summary.get('marker_count', 0)}",
        (
            f"- Markers with raw-motion coverage: "
            f"{summary.get('captured_marker_count', 0)}"
        ),
        "",
    ]
    completed_marker_count = int(
        number(summary.get("completed_marker_count")) or 0
    )
    if completed_marker_count != int(
        number(summary.get("marker_count")) or 0
    ):
        lines.insert(
            -1,
            (
                f"- Covered markers in completed blocks: "
                f"{completed_marker_count}"
            ),
        )
    if summary.get("sample_limit_reached"):
        lines.extend(
            [
                "## Capture warning",
                "",
                (
                    "- The recorder reached its sample cap. Blocks after the "
                    "last raw sample are excluded from detector scoring rather "
                    "than treated as missed repetitions."
                ),
                "",
            ]
        )
    if warnings:
        lines.extend(
            [
                "## Parse warnings",
                "",
                *[f"- {warning}" for warning in warnings],
                "",
            ]
        )

    stages = summary.get("stage_summaries", [])
    if isinstance(stages, list) and stages:
        lines.extend(
            [
                "## Labeled blocks",
                "",
                "| Stage | Split | Status | Capture | Markers | Axial RMS g | Gyro peak rad/s | Tilt ° | Detector counts | Rejects |",
                "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
            ]
        )
        for stage in stages:
            metrics = stage.get("metrics", {})
            lines.append(
                "| "
                + " | ".join(
                    [
                        str(stage.get("stage_id", "unknown")),
                        str(stage.get("partition", "train")),
                        str(stage.get("status", "unknown")),
                        str(stage.get("capture_status", "unknown")),
                        str(stage.get("marker_count", 0)),
                        format_number(
                            metrics.get("axial_acceleration_rms_g"), 3
                        ),
                        format_number(
                            metrics.get("gyro_peak_radians_per_second"), 2
                        ),
                        format_number(
                            metrics.get("gravity_tilt_excursion_degrees"), 1
                        ),
                        str(detector_event_count(metrics, "rep_counted")),
                        str(detector_event_count(metrics, "attempt_rejected")),
                    ]
                )
                + " |"
            )
        lines.append("")
    else:
        lines.extend(
            [
                "## Labeled blocks",
                "",
                "No diagnostic stage labels were found. This is a legacy trace; "
                "raw signal quality can be inspected, but detector accuracy cannot "
                "be scored without user-confirmed endpoints.",
                "",
            ]
        )

    alignment = summary.get("marker_alignment", [])
    if isinstance(alignment, list) and alignment:
        offsets = [
            float(item["offset_seconds"])
            for item in alignment
            if item.get("matched") and item.get("offset_seconds") is not None
        ]
        unmatched = sum(not bool(item.get("matched")) for item in alignment)
        complete_reps = summary.get("complete_rep_alignment", [])
        if not isinstance(complete_reps, list):
            complete_reps = []
        coherent_reps = sum(
            bool(rep.get("matched")) for rep in complete_reps
        )
        training_reps = [
            rep for rep in complete_reps if rep.get("partition") == "train"
        ]
        evaluation_reps = [
            rep
            for rep in complete_reps
            if rep.get("partition") == "evaluation"
        ]
        coherent_training_reps = sum(
            bool(rep.get("matched")) for rep in training_reps
        )
        coherent_evaluation_reps = sum(
            bool(rep.get("matched")) for rep in evaluation_reps
        )
        evaluation_text = (
            f"{coherent_evaluation_reps} / {len(evaluation_reps)}"
            if evaluation_reps
            else "unavailable"
        )
        lines.extend(
            [
                "## Baseline detector alignment",
                "",
                (
                    f"- Coherent complete reps: {coherent_reps} / "
                    f"{len(complete_reps)} "
                    f"(train {coherent_training_reps} / "
                    f"{len(training_reps)}; evaluation "
                    f"{evaluation_text})."
                ),
                (
                    f"- Stage-scoped matched endpoints: "
                    f"{len(offsets)} / {len(alignment)}; "
                    f"unmatched: {unmatched}."
                ),
                (
                    "- Median detector-minus-marker offset: "
                    f"{format_number(statistics.median(offsets) if offsets else None, 3)} s."
                ),
                (
                    "- Negative means the detector fired before the user-confirmed "
                    "endpoint; positive means it fired late."
                ),
                "",
            ]
        )

    negative_stage_ids = {
        "stillness_control",
        "arms_only_control",
        "hinge_control",
        "shallow_control",
        "held_out_stillness",
        "haptic_probe",
    }
    false_counts: list[str] = []
    captured_negative_blocks = 0
    missing_negative_blocks: list[str] = []
    if isinstance(stages, list):
        for stage in stages:
            if stage.get("stage_id") not in negative_stage_ids:
                continue
            if stage.get("capture_status") == "missing":
                missing_negative_blocks.append(str(stage.get("stage_id")))
                continue
            captured_negative_blocks += 1
            metrics = stage.get("metrics", {})
            count = detector_event_count(metrics, "rep_counted")
            if count:
                false_counts.append(f"{stage.get('stage_id')}: {count}")
    lines.extend(["## Heuristic decision checks", ""])
    if false_counts:
        lines.append(
            "- Baseline false reps in negative controls: "
            + ", ".join(false_counts)
            + "."
        )
    elif captured_negative_blocks:
        lines.append("- Baseline produced no reps in captured negative controls.")
    else:
        lines.append("- Negative-control scoring awaits a labeled Squat Lab run.")
    if missing_negative_blocks:
        lines.append(
            "- Raw samples were unavailable for: "
            + ", ".join(dict.fromkeys(missing_negative_blocks))
            + "."
        )
    lines.extend(
        [
            "- Tune only on `train` blocks; reserve `evaluation` blocks for the final comparison.",
            "- Rank candidates by zero negative-control reps, held-out rep count, endpoint timing, hold stability, and recovery after partial motion.",
            "- If arms-only motion overlaps full-squat features, constrain phone placement rather than hiding the ambiguity with looser thresholds.",
            "",
        ]
    )
    return "\n".join(lines)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the analyzer and write requested outputs."""
    arguments = parse_args(argv or sys.argv[1:])
    try:
        records, warnings = load_records(arguments.trace)
    except OSError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if not records:
        print("error: trace contains no valid records", file=sys.stderr)
        return 2

    summary = build_summary(records)
    print(render_markdown(summary, warnings))
    if arguments.json_output is not None:
        try:
            arguments.json_output.parent.mkdir(parents=True, exist_ok=True)
            arguments.json_output.write_text(
                json.dumps(summary, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
        except OSError as error:
            print(f"error writing JSON summary: {error}", file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
