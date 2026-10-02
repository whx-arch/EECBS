#!/usr/bin/env python3
"""Run the stratified kernel in gem5 (SE mode) for one configuration and combine the strata.

For every stratum written by `select_trace.py --stratify PREFIX` this launches
    gem5.opt --outdir=<outroot>/s<k> se.py --cmd=<static m5ops kernel> --options="... --warmup W --iters N"
            <gem5 args> --fast-forward=<setup instructions>
(all strata in parallel), takes the FIRST statistics block of each stats.txt (the region between
m5_reset_stats() and m5_dump_stats(), i.e. exactly the measured calls), checks that the kernel
reported the expected number of expanded nodes, and scales each stratum by
(population expanded nodes / measured expanded nodes) to estimate whole-run totals.

Two input layouts:
  strata  : --prefix P   (P<k>.trace + P.manifest from select_trace.py --stratify; strata run in parallel)
  single  : --single F --warm W --total-exp N   (one file from select_trace.py --every K --by-size; the whole
            run's expanded nodes N (from --stats-only) is divided by the measured expansions to scale totals)
Add --auto-setup to measure the kernel's setup length natively (perf) instead of using --setup-insts.

usage:
  run_gem5.py --prefix kernel/traces/m2_s --outroot runs/baseline \
      --gem5-args "--cpu-type=DerivO3CPU --caches --l2cache" [--strata 0,1,2,3]
  run_gem5.py --prefix ... --outroot runs/baseline --no-run     # only (re)parse existing outputs

Run from the repo root (map/scen/trace paths are relative to the gem5 process' cwd).
"""
import argparse
import json
import os
import re
import shlex
import subprocess
import sys

HOME = os.path.expanduser("~")


def read_manifest(prefix):
    strata = []
    for line in open(prefix + ".manifest"):
        if line.startswith("#") or not line.strip():
            continue
        f = line.split()
        strata.append(dict(s=int(f[0]), name="s%s" % f[0], trace="%s%s.trace" % (prefix, f[0]), pop=int(f[3]),
                           pop_exp=int(f[4]), warm=int(f[5]), roi=int(f[6]), roi_exp=int(f[7]),
                           xscale=float(f[4]) / float(f[7])))
    return strata


def first_block(stats_path):
    """Lines of the first 'Begin/End Simulation Statistics' block as {name: float}."""
    vals = {}
    inside = False
    with open(stats_path) as f:
        for line in f:
            if "Begin Simulation Statistics" in line:
                if inside:
                    break
                inside = True
                continue
            if "End Simulation Statistics" in line:
                break
            if not inside:
                continue
            parts = line.split()
            if len(parts) >= 2:
                try:
                    vals[parts[0]] = float(parts[1])
                except ValueError:
                    pass
    return vals


def pick_max(vals, regex):
    """Largest value among stats whose name matches regex (the CPU that actually ran)."""
    r = re.compile(regex)
    cands = [(v, k) for k, v in vals.items() if r.search(k)]
    return max(cands) if cands else (0.0, None)


def summarize(vals):
    out = {}
    out["insts"] = vals.get("simInsts", 0.0)
    out["cycles"], _ = pick_max(vals, r"^system\.[\w.]*numCycles$")
    out["cond_predicted"], _ = pick_max(vals, r"branchPred\.condPredicted$")
    out["cond_incorrect"], _ = pick_max(vals, r"branchPred\.condIncorrect$")
    for cache in ("icache", "dcache", "l2cache", "l3cache", "l2", "l3"):
        miss, kname = pick_max(vals, r"\.%s\.overallMisses::total$" % cache)
        acc, _ = pick_max(vals, r"\.%s\.overallAccesses::total$" % cache)
        if kname is not None and acc > 0:
            out[cache + "_misses"] = miss
            out[cache + "_accesses"] = acc
    return out


def native_expanded(native_bin, a, st):
    """Expanded nodes of the same stratum replayed natively with the same arguments (default seed).
    gem5 must reproduce this exactly: same binary logic, same libc rand() stream."""
    if not native_bin or not os.path.exists(native_bin):
        return None
    cmd = [native_bin, "--map", a.map, "--scen", a.scen, "--trace", st["trace"],
           "--warmup", str(st["warm"]), "--iters", str(st["roi"])]
    p = subprocess.run(cmd, capture_output=True, text=True)
    m = re.search(r"calls=\d+ expanded=(\d+)", p.stdout)
    return int(m.group(1)) if m else None


def expected_line_ok(stdout_path, native_exp, manifest_exp):
    try:
        text = open(stdout_path, errors="replace").read()
    except OSError:
        return None, "no stdout"
    m = re.search(r"calls=\d+ expanded=(\d+)", text)
    if not m:
        return False, "kernel did not print its result line"
    got = int(m.group(1))
    if native_exp is not None:
        return got == native_exp, "gem5 kernel reported expanded=%d, native replay of the same stratum reports %d" % (got, native_exp)
    # no native binary: the manifest holds the REAL run's counts, which differ slightly for calls that
    # found a path (tie-breaking randomness), so only a loose check is possible
    return abs(got - manifest_exp) <= 0.1 * manifest_exp,         "kernel reported expanded=%d, manifest (real run) has %d (loose 10%% check, no --native-bin)" % (got, manifest_exp)


def single_stratum(trace, warm, total_exp):
    """One pseudo-stratum for a single-file sample (CALL lines: 'CALL id agent lb w expanded generated')."""
    exps = []
    with open(trace) as f:
        for line in f:
            if line.startswith("CALL "):
                exps.append(int(line.split()[5]))
    roi_exp = sum(exps[warm:])
    return dict(s=0, name="single", trace=trace, pop=len(exps) - warm, pop_exp=total_exp or roi_exp, warm=warm,
                roi=len(exps) - warm, roi_exp=roi_exp, xscale=(total_exp / roi_exp) if total_exp else 1.0)


def measure_setup(native_bin, a, st):
    """Instructions the kernel executes before its first call (setup), measured natively with perf.
    Returns 95% of it so the fast-forward ends just inside the setup (never past it)."""
    cmd = ["perf", "stat", "-x,", "-e", "cpu_core/instructions/u", native_bin, "--map", a.map, "--scen", a.scen,
           "--trace", st["trace"], "--warmup", "0", "--iters", "0"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    for line in p.stderr.splitlines():
        parts = line.split(",")
        if len(parts) >= 3 and "instructions" in parts[2]:
            try:
                return int(0.95 * float(parts[0]))
            except ValueError:
                pass
    sys.exit("could not measure the setup length with perf:\n" + p.stderr[-1000:])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--prefix", help="stratified trace prefix (PREFIX<k>.trace, PREFIX.manifest)")
    ap.add_argument("--single", help="single-file sample instead of strata")
    ap.add_argument("--warm", type=int, default=2, help="with --single: warm-up calls at the start of the file")
    ap.add_argument("--total-exp", type=int, default=0,
                    help="with --single: expanded nodes of the whole run (scales totals; rates need no scaling)")
    ap.add_argument("--auto-setup", action="store_true", help="measure the setup length natively with perf")
    ap.add_argument("--outroot", required=True)
    ap.add_argument("--gem5", default=os.path.join(HOME, "gem5/build/X86/gem5.opt"))
    ap.add_argument("--se", default=os.path.join(HOME, "gem5/configs/deprecated/example/se.py"))
    ap.add_argument("--bin", default="kernel/build-gem5/lowlevel_kernel")
    ap.add_argument("--map", default="maze-32-32-2.map")
    ap.add_argument("--scen", default="maze-32-32-2-random-1.scen")
    ap.add_argument("--setup-insts", type=int, default=18500000,
                    help="instructions to fast-forward (just below the kernel's setup length)")
    ap.add_argument("--native-bin", default="kernel/build/lowlevel_kernel",
                    help="native (non-gem5) kernel used to compute the expected expanded count of each stratum")
    ap.add_argument("--gem5-args", default="--cpu-type=DerivO3CPU --caches --l2cache")
    ap.add_argument("--strata", default="", help="comma-separated stratum ids (default: all)")
    ap.add_argument("--no-run", action="store_true", help="do not launch gem5, only parse existing outputs")
    a = ap.parse_args()

    if a.single:
        strata = [single_stratum(a.single, a.warm, a.total_exp)]
    elif a.prefix:
        strata = read_manifest(a.prefix)
    else:
        sys.exit("give --prefix (strata) or --single (one file)")
    if a.strata and not a.single:
        want = {int(x) for x in a.strata.split(",")}
        strata = [s for s in strata if s["s"] in want]

    procs = []
    if not a.no_run:
        for st in strata:
            setup_insts = measure_setup(a.native_bin, a, st) if a.auto_setup else a.setup_insts
            print("%s: fast-forward %d instructions" % (st["name"], setup_insts), flush=True)
            outdir = os.path.join(a.outroot, st["name"])
            os.makedirs(outdir, exist_ok=True)
            options = "--map %s --scen %s --trace %s --warmup %d --iters %d" % (
                a.map, a.scen, st["trace"], st["warm"], st["roi"])
            cmd = [a.gem5, "--outdir=" + outdir, a.se, "--cmd=" + a.bin, "--options=" + options]
            cmd += shlex.split(a.gem5_args) + ["--fast-forward=%d" % setup_insts]
            with open(os.path.join(outdir, "command.txt"), "w") as f:
                f.write(" ".join(shlex.quote(c) for c in cmd) + "\n")
            log = open(os.path.join(outdir, "stdout.txt"), "w")
            print("launching %s: %s" % (st["name"], outdir), flush=True)
            procs.append((st, subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)))
        for st, p in procs:
            rc = p.wait()
            print("%s finished (exit %d)" % (st["name"], rc), flush=True)

    total = {}
    rows = []
    problems = []
    for st in strata:
        outdir = os.path.join(a.outroot, st["name"])
        stats = os.path.join(outdir, "stats.txt")
        if not os.path.exists(stats):
            problems.append("%s: no stats.txt" % st["name"])
            continue
        vals = first_block(stats)
        summ = summarize(vals)
        ok, msg = expected_line_ok(os.path.join(outdir, "stdout.txt"), native_expanded(a.native_bin, a, st), st["roi_exp"])
        if ok is not True:
            problems.append("%s: %s" % (st["name"], msg))
        if summ["insts"] <= 0 or summ["cycles"] <= 0:
            problems.append("%s: first stats block has no instructions/cycles (ROI ran in the fast CPU?)" % st["name"])
        rows.append((st, summ))
        for k, v in summ.items():
            total[k] = total.get(k, 0.0) + st["xscale"] * v
        with open(os.path.join(outdir, "roi_stats_summary.json"), "w") as f:
            json.dump(summ, f, indent=1)

    print()
    for st, s in rows:
        line = "%s: %.3g instr, %.3g cycles, CPI %.3f" % (st["name"], s["insts"], s["cycles"], s["cycles"] / s["insts"])
        if s["cond_predicted"] > 0:
            line += ", cond-branch miss %.2f%%, MPKI %.2f" % (100 * s["cond_incorrect"] / s["cond_predicted"],
                                                             1000 * s["cond_incorrect"] / s["insts"])
        print(line)
    if total.get("insts"):
        print("\nwhole-run estimate (expansion-scaled): %.4g instr, %.4g cycles, CPI %.3f"
              % (total["insts"], total["cycles"], total["cycles"] / total["insts"]))
        if total.get("cond_predicted"):
            print("  cond-branch miss %.2f%%, MPKI %.2f"
                  % (100 * total["cond_incorrect"] / total["cond_predicted"], 1000 * total["cond_incorrect"] / total["insts"]))
        for c in ("icache", "dcache", "l2cache", "l3cache", "l2", "l3"):
            if c + "_misses" in total:
                print("  %s miss rate %.2f%%, %.2f misses per 1000 instr"
                      % (c, 100 * total[c + "_misses"] / total[c + "_accesses"], 1000 * total[c + "_misses"] / total["insts"]))
        print("  cycle share per stratum: " + ", ".join(
            "%s %.1f%%" % (st["name"], 100.0 * st["xscale"] * s["cycles"] / total["cycles"]) for st, s in rows))
        with open(os.path.join(a.outroot, "summary.json"), "w") as f:
            json.dump(total, f, indent=1)
    for p in problems:
        print("WARNING: " + p, file=sys.stderr)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
