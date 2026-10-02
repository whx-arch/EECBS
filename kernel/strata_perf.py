#!/usr/bin/env python3
"""Check the stratified sample against a full replay using hardware counters (perf stat).

For every stratum written by `select_trace.py --stratify PREFIX`, the kernel is run twice:
    A: --warmup W --iters 0      (setup + warm-up calls only)
    B: --warmup W --iters N      (setup + warm-up calls + the measured calls)
B - A is the counter delta of the measured calls alone, with the same warmed-up state the
gem5 run will have. Scaling each stratum by population/measured calls and summing gives an
estimate of the whole run, compared against the same A/B difference for a replay of the full
trace.

usage: strata_perf.py --bin ./lowlevel_kernel --map M --scen S --prefix kernel/traces/m2_s \
                      --full-trace /tmp/m2_full.trace [--cpu 2] [--reps 3]

Needs `perf` (sudo dnf install perf). On this hybrid CPU the events are pinned to the P-core PMU
(cpu_core); use --events to override on other machines.
"""
import argparse
import statistics
import subprocess
import sys

KEYS = ("cycles", "instructions", "branches", "branch-misses")
DEFAULT_EVENTS = "cpu_core/cycles/u,cpu_core/instructions/u,cpu_core/branches/u,cpu_core/branch-misses/u"


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


def delta(args, trace, warm, iters):
    base = [args.bin, "--map", args.map, "--scen", args.scen, "--trace", trace]
    rows = []
    for _ in range(args.reps):
        a = perf_run(args.cpu, args.events, base + ["--warmup", str(warm), "--iters", "0"])
        b = perf_run(args.cpu, args.events, base + ["--warmup", str(warm), "--iters", str(iters)])
        rows.append({k: b[k] - a[k] for k in KEYS})
    return {k: statistics.median(r[k] for r in rows) for k in KEYS}


def derived(c):
    return ("CPI %.3f  branch-miss rate %.2f%%  MPKI %.2f"
            % (c["cycles"] / c["instructions"], 100.0 * c["branch-misses"] / c["branches"],
               1000.0 * c["branch-misses"] / c["instructions"]))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--map", required=True)
    ap.add_argument("--scen", required=True)
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--full-trace", required=True)
    ap.add_argument("--cpu", type=int, default=2, help="P-core to pin to")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--events", default=DEFAULT_EVENTS)
    args = ap.parse_args()

    strata = []
    for line in open(args.prefix + ".manifest"):
        if line.startswith("#") or not line.strip():
            continue
        f = line.split()
        strata.append(dict(s=int(f[0]), pop=int(f[3]), warm=int(f[5]), roi=int(f[6]), scale=float(f[8]),
                           # ratio estimator: scale by expanded nodes instead of call counts, which cancels
                           # the error from sampled calls being bigger/smaller than the stratum average
                           xscale=float(f[4]) / float(f[7])))

    est = {k: 0.0 for k in KEYS}
    est_x = {k: 0.0 for k in KEYS}
    stratum_cycles = []
    for st in strata:
        trace = "%s%d.trace" % (args.prefix, st["s"])
        d = delta(args, trace, st["warm"], st["roi"])
        print("stratum %d (%d measured calls, x%.1f): %.3g instr, %.3g cycles; %s"
              % (st["s"], st["roi"], st["scale"], d["instructions"], d["cycles"], derived(d)))
        for k in KEYS:
            est[k] += st["scale"] * d[k]
            est_x[k] += st["xscale"] * d[k]
        stratum_cycles.append(st["xscale"] * d["cycles"])

    ncalls = sum(st["pop"] for st in strata)
    full = delta(args, args.full_trace, 0, ncalls)
    print()
    print("%-14s %14s %8s %14s %8s %14s" % ("metric", "count-scaled", "error", "expansion-scaled", "error", "full replay"))
    for k in KEYS:
        print("%-14s %14.4g %+7.1f%% %14.4g %+7.1f%% %14.4g"
              % (k, est[k], 100.0 * (est[k] - full[k]) / full[k], est_x[k],
                 100.0 * (est_x[k] - full[k]) / full[k], full[k]))
    print("count-scaled    : " + derived(est))
    print("expansion-scaled: " + derived(est_x))
    print("full replay     : " + derived(full))
    tot = sum(stratum_cycles)
    print("cycle share per stratum (expansion-scaled): " +
          ", ".join("s%d %.1f%%" % (st["s"], 100.0 * c / tot) for st, c in zip(strata, stratum_cycles)))


if __name__ == "__main__":
    main()
