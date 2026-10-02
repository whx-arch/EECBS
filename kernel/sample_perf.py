#!/usr/bin/env python3
"""Compare single-file samples (select_trace.py --every / --window-start) with a full replay.

Each sample is run as `--warmup W --iters N` twice (N = 0 and N = measured calls); the difference of
the perf counters is the measured region alone (same trick as strata_perf.py). Rates (CPI, branch
miss rate, MPKI) are compared with the same difference for a replay of the full trace, so no
scaling is needed.

usage: sample_perf.py --bin kernel/build/lowlevel_kernel --map M --scen S --full-trace /tmp/m2_full.trace \
           --warm 2 kernel/traces/seq16_o0.trace kernel/traces/win800.trace ...
(--warm must match the --warm used with select_trace.py for every file given)
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import strata_perf as sp  # noqa: E402


def count_calls(path):
    with open(path) as f:
        return sum(1 for line in f if line.startswith("CALL "))


def rates(c):
    return (c["cycles"] / c["instructions"],
            100.0 * c["branch-misses"] / c["branches"],
            1000.0 * c["branch-misses"] / c["instructions"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--map", required=True)
    ap.add_argument("--scen", required=True)
    ap.add_argument("--full-trace", required=True)
    ap.add_argument("--warm", type=int, default=2)
    ap.add_argument("--cpu", type=int, default=2)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--events", default=sp.DEFAULT_EVENTS)
    ap.add_argument("samples", nargs="+")
    a = ap.parse_args()

    full = sp.delta(a, a.full_trace, 0, count_calls(a.full_trace))
    f_cpi, f_miss, f_mpki = rates(full)
    print("%-34s %8s %8s %8s   %s" % ("", "CPI", "miss%", "MPKI", "instr (measured)"))
    print("%-34s %8.3f %8.2f %8.2f   %.3g" % ("full replay", f_cpi, f_miss, f_mpki, full["instructions"]))
    for path in a.samples:
        n = count_calls(path) - a.warm
        d = sp.delta(a, path, a.warm, n)
        cpi, miss, mpki = rates(d)
        print("%-34s %8.3f %8.2f %8.2f   %.3g   (CPI %+.1f%%, miss rate %+.1f%%, MPKI %+.1f%%)"
              % (os.path.basename(path), cpi, miss, mpki, d["instructions"],
                 100 * (cpi - f_cpi) / f_cpi, 100 * (miss - f_miss) / f_miss, 100 * (mpki - f_mpki) / f_mpki))


if __name__ == "__main__":
    main()
