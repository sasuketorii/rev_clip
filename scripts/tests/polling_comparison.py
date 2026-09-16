#!/usr/bin/env python3
"""Summarize an existing serialized XCTest log; never launch tests or applications.

Usage: python3 scripts/tests/polling_comparison.py LOG
Requires all 54 rows (three shared phases) from testBoundedAdaptivePoliciesAgainstFixed500ms.
Experiment xcodebuild selector:
  -only-testing:RevclipTests/RCClipboardPollingTests/testBoundedAdaptivePoliciesAgainstFixed500ms
Regular suite exclusion:
  -skip-testing:RevclipTests/RCClipboardPollingTests/testBoundedAdaptivePoliciesAgainstFixed500ms
Keep the parent's existing Release/RC_TESTING isolation and serialized execution.
"""
import argparse
import json
import math
from pathlib import Path


def summarize(path):
    rows = {}
    prefix = "RC_POLLING_COMPARISON "
    with path.open(errors="replace") as log:
        for line in log:
            if prefix not in line:
                continue
            row = json.loads(line.split(prefix, 1)[1])
            key = row["trial"], row["phase_ms"], row["producer_interval_ms"], row["policy"]
            if key in rows:
                raise ValueError(f"Duplicate trial {key}; supply one test run")
            if row["measurement_scope"] != "single_XCTest_host_process_short_synthetic_trial":
                raise ValueError("Unexpected measurement scope")
            if row["persistence"] != "in_memory_boundary_not_disk":
                raise ValueError("Unexpected persistence boundary")
            if row["observed_count"] != row["processed_count"]:
                raise ValueError(f"Observed snapshot lost before fake processing: {key}")
            if row["produced_count"] != (row["observed_count"] +
                    row["overwritten_before_observation_count"] + row["unobserved_at_stop_count"]):
                raise ValueError(f"Unaccounted snapshot: {key}")
            rows[key] = row
    policies = ("fixed_500ms", "bounded_250ms", "bounded_100ms")
    cadences = (1000, 500, 250, 100, 50, 0)
    phases = (73, 137, 311)
    expected = {(trial, phase, cadence, policy) for trial, phase in enumerate(phases, 1)
                for cadence in cadences for policy in policies}
    if set(rows) != expected:
        raise ValueError(f"Incomplete/unexpected trial matrix: missing={sorted(expected-set(rows))}, extra={sorted(set(rows)-expected)}")
    print("Short synthetic named-board comparison; fake processing, not disk persistence.")
    print("CPU/RSS cover the XCTest host process, including instrumentation; not isolated service energy or a long-duration idle benchmark.\n")
    print("| Trial | Phase ms | Producer ms | Policy | Produced | Observed | Overwritten | Pending | Processed | Polls | CPU ms | CPU % | RSS start/end/peak MiB | Latency p50/p95 ms |")
    print("| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |")
    for trial, phase in enumerate(phases, 1):
        for cadence in cadences:
            for policy in policies:
                row = rows[trial, phase, cadence, policy]
                values = sorted(row["acquisition_latency_ms"])
                latency = "/".join(f"{values[max(0, math.ceil(len(values)*p)-1)]:.1f}" for p in (.5, .95)) if values else "—"
                memory = "/".join(f"{row[k]/(1024**2):.2f}" for k in ("rss_start_bytes", "rss_end_bytes", "rss_sampled_peak_bytes"))
                print(f"| {trial} | {phase} | {cadence or 'idle 3s'} | {policy} | {row['produced_count']} | {row['observed_count']} | "
                      f"{row['overwritten_before_observation_count']} | {row['unobserved_at_stop_count']} | "
                      f"{row['processed_count']} | {row['poll_count']} | {row['process_cpu_ms']:.2f} | "
                      f"{row['process_cpu_percent']:.2f} | {memory} | {latency} |")
    print("\nNo claim of 10-minute idle, 30-minute mixed use, real clipboard capture, disk durability, or a production-policy recommendation follows from this run.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    try:
        summarize(args.log)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Invalid benchmark evidence: {error}\n")
