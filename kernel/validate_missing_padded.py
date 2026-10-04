#!/usr/bin/env python3
"""Padded validation for the 3 maps missing from the original batch.

Loads the full trace to establish correct cache/predictor state, places the
sample calls at the front, and measures with perf. This matches the padded
validation used for the other 11 maps.

Run from the EECBS repo root:
    python3 -u kernel/validate_missing_padded.py 2>&1 | tee kernel/traces/missing_padded_validation.log
"""

import hashlib
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

KEYS = ("cycles", "instructions", "branches", "branch-misses")
DEFAULT_EVENTS = "cpu_core/cycles/u,cpu_core/instructions/u,cpu_core/branches/u,cpu_core/branch-misses/u"

MAPS = (
    ("randomA", "random-32-32-20.map", "random-32-32-20-random-1.scen",
     "randomA_full.trace", "randomA_bs32_o7.trace"),
    ("maze128_10", "maze-128-128-10.map", "maze-128-128-10-random-1.scen",
     "maze128_10_full.trace", "maze128_10_bs32_o7.trace"),
    ("ost003d", "ost003d.map", "ost003d-random-1.scen",
     "ost003d_full.trace", "ost003d_bs8_o3.trace"),
)


def perf_run(cpu, events, cmd):
    full = ["taskset", "-c", str(cpu), "perf", "stat", "-x,", "-e", events] + cmd
    p = subprocess.run(full, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit("command failed:\n%s\n%s" % (" ".join(full), p.stderr[-2000:]))
    counts = {}
    for line in p.stderr.splitlines():
        parts = line.split(",")
        if len(parts) < 3:
            continue
        try:
            v = float(parts[0])
        except ValueError:
            continue
        for key in ("branch-misses", "branches", "instructions", "cycles"):
            if key in parts[2]:
                counts[key] = v
                break
    missing = [k for k in KEYS if k not in counts]
    if missing:
        sys.exit("perf did not report %s; raw output:\n%s" % (missing, p.stderr[-2000:]))
    return counts


def delta(bin_path, map_path, scen_path, trace, warm, iters, cpu, events, reps):
    base = [bin_path, "--map", map_path, "--scen", scen_path, "--trace", trace]
    rows = []
    for _ in range(reps):
        a = perf_run(cpu, events, base + ["--warmup", str(warm), "--iters", "0"])
        b = perf_run(cpu, events, base + ["--warmup", str(warm), "--iters", str(iters)])
        rows.append({k: b[k] - a[k] for k in KEYS})
    return {k: statistics.median(r[k] for r in rows) for k in KEYS}


def rates(counts):
    return {
        "cpi": counts["cycles"] / counts["instructions"],
        "branch_miss_pct": 100 * counts["branch-misses"] / counts["branches"],
        "mpki": 1000 * counts["branch-misses"] / counts["instructions"],
        "instructions": counts["instructions"],
    }


def count_calls(path):
    with open(path, "rb") as f:
        return sum(line.startswith(b"CALL ") for line in f)


def read_header(source):
    header = bytearray()
    while True:
        position = source.tell()
        line = source.readline()
        if not line:
            raise ValueError("trace has no CALL blocks")
        if line.startswith(b"CALL "):
            source.seek(position)
            return bytes(header)
        header.extend(line)


def iter_blocks(source):
    block = bytearray()
    call_id = None
    for line in source:
        if line.startswith(b"CALL "):
            if call_id is not None:
                raise ValueError("nested CALL")
            call_id = int(line.split()[1])
            block.extend(line)
        elif call_id is None:
            if line.strip():
                raise ValueError(f"unexpected text between calls: {line[:80]!r}")
        else:
            block.extend(line)
            if line.strip() == b"END":
                yield call_id, bytes(block)
                block.clear()
                call_id = None
    if call_id is not None:
        raise ValueError("incomplete final CALL block")


def make_padded(full, sample, output):
    """Place sample calls at the front of the full trace, keeping all other calls after."""
    full = Path(full)
    sample = Path(sample)
    output = Path(output)
    if output.exists():
        raise FileExistsError(f"output already exists: {output}")

    free = shutil.disk_usage(output.parent).free
    needed = full.stat().st_size + 512 * 1024 * 1024
    if free < needed:
        raise OSError(f"insufficient free disk space: {free} bytes free, {needed} needed")

    selected = {}
    seen = set()
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".padded_",
                                         suffix=".tmp", delete=False) as target:
            temp_name = target.name
            with sample.open("rb") as sf:
                header = read_header(sf)
                target.write(header)
                for call_id, block in iter_blocks(sf):
                    if call_id in selected:
                        raise ValueError(f"duplicate selected CALL {call_id}")
                    selected[call_id] = hashlib.sha256(block).digest()
                    target.write(block)
            with full.open("rb") as ff:
                if read_header(ff) != header:
                    raise ValueError("full and sample TRACE headers differ")
                full_calls = 0
                for call_id, block in iter_blocks(ff):
                    full_calls += 1
                    if call_id in selected:
                        if call_id in seen:
                            raise ValueError(f"duplicate full CALL {call_id}")
                        if hashlib.sha256(block).digest() != selected[call_id]:
                            raise ValueError(f"selected CALL {call_id} differs from full trace")
                        seen.add(call_id)
                    else:
                        target.write(block)
            if seen != selected.keys():
                raise ValueError(f"missing selected CALLs: {selected.keys() - seen}")
            target.flush()
        os.replace(temp_name, output)
        temp_name = None
    finally:
        if temp_name is not None:
            os.unlink(temp_name)
    return len(selected), full_calls


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", default="kernel/build/lowlevel_kernel")
    parser.add_argument("--trace-dir", type=Path, default=Path("kernel/traces"))
    parser.add_argument("--cpu", type=int, default=2)
    parser.add_argument("--events", default=DEFAULT_EVENTS)
    parser.add_argument("--reps", type=int, default=3)
    args = parser.parse_args()

    if not Path(args.bin).is_file():
        sys.exit(f"ERROR: native kernel not found at {args.bin}")

    results = []
    for alias, map_path, scen_path, full_name, sample_name in MAPS:
        full_path = args.trace_dir / full_name
        sample_path = args.trace_dir / sample_name

        for path in (Path(map_path), Path(scen_path)):
            if not path.is_file():
                sys.exit(f"missing file: {path}")
        if not full_path.is_file():
            print(f"[{alias}] SKIP: {full_path} not found", flush=True)
            continue
        if not sample_path.is_file():
            print(f"[{alias}] SKIP: {sample_path} not found", flush=True)
            continue

        print(f"==========================================", flush=True)
        print(f"[{alias}] full={full_name}  sample={sample_name}", flush=True)
        print(f"==========================================", flush=True)

        full_calls = count_calls(full_path)
        roi_calls = count_calls(sample_path) - 2

        # Full replay baseline
        print(f"  measuring full replay ({full_calls} calls)...", flush=True)
        full_rates = rates(delta(args.bin, map_path, scen_path,
                                 str(full_path), 0, full_calls,
                                 args.cpu, args.events, args.reps))

        # Make padded trace (sample calls at front, rest after)
        padded_path = args.trace_dir / f".{alias}_padded_{os.getpid()}.trace"
        try:
            print(f"  building padded trace...", flush=True)
            selected, total = make_padded(full_path, sample_path, padded_path)
            assert selected == roi_calls + 2, f"padded mismatch: {selected} != {roi_calls + 2}"
            assert total == full_calls, f"full count mismatch: {total} != {full_calls}"

            # Padded sample measurement
            print(f"  measuring padded sample ({roi_calls} ROI calls)...", flush=True)
            sample_rates = rates(delta(args.bin, map_path, scen_path,
                                       str(padded_path), 2, roi_calls,
                                       args.cpu, args.events, args.reps))
        finally:
            padded_path.unlink(missing_ok=True)

        cpi_err = 100 * (sample_rates["cpi"] / full_rates["cpi"] - 1)
        miss_err = sample_rates["branch_miss_pct"] - full_rates["branch_miss_pct"]
        mpki_err = 100 * (sample_rates["mpki"] / full_rates["mpki"] - 1)
        roi_hours = sample_rates["instructions"] / 250000 / 3600

        passes = abs(cpi_err) < 10 and abs(miss_err) < 2 and abs(mpki_err) < 15

        row = {
            "alias": alias,
            "sample": sample_name,
            "roi_calls": roi_calls,
            "full_cpi": full_rates["cpi"],
            "sample_cpi": sample_rates["cpi"],
            "cpi_error_pct": cpi_err,
            "branch_miss_error_pp": miss_err,
            "mpki_error_pct": mpki_err,
            "gem5_roi_hours": roi_hours,
            "passes": passes,
        }
        results.append(row)

        status = "PASS" if passes else "FAIL"
        print(f"  full  CPI={full_rates['cpi']:.4f}  miss={full_rates['branch_miss_pct']:.3f}%  MPKI={full_rates['mpki']:.3f}", flush=True)
        print(f"  padded CPI={sample_rates['cpi']:.4f}  miss={sample_rates['branch_miss_pct']:.3f}%  MPKI={sample_rates['mpki']:.3f}", flush=True)
        print(f"  [{status}] CPI {cpi_err:+.2f}%  miss {miss_err:+.3f} pp  MPKI {mpki_err:+.2f}%  ROI ~{roi_hours:.2f}h", flush=True)
        print(f"RESULT {json.dumps(row)}", flush=True)
        print("", flush=True)

    passed = sum(r["passes"] for r in results)
    print(f"SUMMARY {passed}/{len(results)} passed", flush=True)


if __name__ == "__main__":
    main()
