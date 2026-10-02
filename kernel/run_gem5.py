#!/usr/bin/env python3
"""Run the stratified kernel in gem5 (SE mode) for one configuration and combine the strata.

For every stratum written by `select_trace.py --stratify PREFIX` this launches
    gem5.opt --outdir=<outroot>/s<k> se.py --cmd=<static m5ops kernel> --options="... --warmup W --iters N"
            <gem5 args> --fast-forward=<setup instructions>
(all strata in parallel), takes the FIRST statistics block of each stats.txt (the region between
m5_reset_stats() and m5_dump_stats(), i.e. exactly the measured calls), checks that the kernel
reported the expected number of expanded nodes, and scales each stratum by
(population expanded nodes / measured expanded nodes) to estimate whole-run totals.

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
        strata.append(dict(s=int(f[0]), pop=int(f[3]), pop_exp=int(f[4]), warm=int(f[5]), roi=int(f[6]),
                           roi_exp=int(f[7]), xscale=float(f[4]) / float(f[7])))
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


def expected_line_ok(stdout_path, roi_exp):
    try:
        text = open(stdout_path, errors="replace").read()
    except OSError:
        return None, "no stdout"
    m = re.search(r"calls=\d+ expanded=(\d+)", text)
    if not m:
        return False, "kernel did not print its result line"
    got = int(m.group(1))
    return got == roi_exp, "kernel reported expanded=%d, manifest expects %d" % (got, roi_exp)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--prefix", required=True, help="stratified trace prefix (PREFIX<k>.trace, PREFIX.manifest)")
    ap.add_argument("--outroot", required=True)
    ap.add_argument("--gem5", default=os.path.join(HOME, "gem5/build/X86/gem5.opt"))
    ap.add_argument("--se", default=os.path.join(HOME, "gem5/configs/deprecated/example/se.py"))
    ap.add_argument("--bin", default="kernel/build-gem5/lowlevel_kernel")
    ap.add_argument("--map", default="maze-32-32-2.map")
    ap.add_argument("--scen", default="maze-32-32-2-random-1.scen")
    ap.add_argument("--setup-insts", type=int, default=18500000,
                    help="instructions to fast-forward (just below the kernel's setup length)")
    ap.add_argument("--gem5-args", default="--cpu-type=DerivO3CPU --caches --l2cache")
    ap.add_argument("--strata", default="", help="comma-separated stratum ids (default: all)")
    ap.add_argument("--no-run", action="store_true", help="do not launch gem5, only parse existing outputs")
    a = ap.parse_args()

    strata = read_manifest(a.prefix)
    if a.strata:
        want = {int(x) for x in a.strata.split(",")}
        strata = [s for s in strata if s["s"] in want]

    procs = []
    if not a.no_run:
        for st in strata:
            outdir = os.path.join(a.outroot, "s%d" % st["s"])
            os.makedirs(outdir, exist_ok=True)
            options = "--map %s --scen %s --trace %s%d.trace --warmup %d --iters %d" % (
                a.map, a.scen, a.prefix, st["s"], st["warm"], st["roi"])
            cmd = [a.gem5, "--outdir=" + outdir, a.se, "--cmd=" + a.bin, "--options=" + options]
            cmd += shlex.split(a.gem5_args) + ["--fast-forward=%d" % a.setup_insts]
            with open(os.path.join(outdir, "command.txt"), "w") as f:
                f.write(" ".join(shlex.quote(c) for c in cmd) + "\n")
            log = open(os.path.join(outdir, "stdout.txt"), "w")
            print("launching stratum %d: %s" % (st["s"], outdir), flush=True)
            procs.append((st, subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)))
        for st, p in procs:
            rc = p.wait()
            print("stratum %d finished (exit %d)" % (st["s"], rc), flush=True)

    total = {}
    rows = []
    problems = []
    for st in strata:
        outdir = os.path.join(a.outroot, "s%d" % st["s"])
        stats = os.path.join(outdir, "stats.txt")
        if not os.path.exists(stats):
            problems.append("stratum %d: no stats.txt" % st["s"])
            continue
        vals = first_block(stats)
        summ = summarize(vals)
        ok, msg = expected_line_ok(os.path.join(outdir, "stdout.txt"), st["roi_exp"])
        if ok is not True:
            problems.append("stratum %d: %s" % (st["s"], msg))
        if summ["insts"] <= 0 or summ["cycles"] <= 0:
            problems.append("stratum %d: first stats block has no instructions/cycles (ROI ran in the fast CPU?)" % st["s"])
        rows.append((st, summ))
        for k, v in summ.items():
            total[k] = total.get(k, 0.0) + st["xscale"] * v
        with open(os.path.join(outdir, "roi_stats_summary.json"), "w") as f:
            json.dump(summ, f, indent=1)

    print()
    for st, s in rows:
        line = "stratum %d: %.3g instr, %.3g cycles, CPI %.3f" % (st["s"], s["insts"], s["cycles"], s["cycles"] / s["insts"])
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
            "s%d %.1f%%" % (st["s"], 100.0 * st["xscale"] * s["cycles"] / total["cycles"]) for st, s in rows))
        with open(os.path.join(a.outroot, "summary.json"), "w") as f:
            json.dump(total, f, indent=1)
    for p in problems:
        print("WARNING: " + p, file=sys.stderr)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
