#!/usr/bin/env python3
"""Select low-level calls from a full trace written by a -DKERNEL_TRACE build.

Modes
  --stats-only                       distribution of expanded nodes per call
  OUT_TRACE [--top N] [--min-expanded X]   keep the heaviest calls (a single trace file)
  --stratify PREFIX --bounds B1,B2,.. [--per N] [--warm W]
                                     stratified sample, one trace file per stratum
  OUT_TRACE --every K [--offset O] [--by-size] [--warm W]
                                     one file: every K-th call; with --by-size the calls are first sorted
                                     by size so the sample's size mix matches the whole run (no luck in how
                                     many heavy calls get picked); the picked calls are then put back in
                                     their original order
  OUT_TRACE --window-start S --window-len L [--warm W]
                                     one file: L consecutive calls from call S, preceded by the
                                     W calls just before S as warm-up
Both single-file modes keep the original call order, so the interleaving of small and large
calls (cache / predictor carry-over) is preserved; the first W calls of the file are warm-up
(--warmup W), the rest are measured (--iters <calls - W>).

Stratified sampling (for gem5, where the full trace is far too long):
  * calls are split into strata by expanded-node count: [0,B1), [B1,B2), ..., [Bk,inf)
  * inside a stratum, calls are sorted by size and N+W are picked at evenly spaced quantiles
    (systematic sampling), so the sample mean tracks the stratum mean
  * W of the picks become warm-up calls, the other N are the measured calls; the two groups
    are disjoint and the warm-up calls come first in the file, so replaying them with
        --warmup W --iters N
    runs every call exactly once (replaying the same call twice would let the branch
    predictor memorise its exact branch sequence)
  * PREFIX.manifest lists, per stratum, the population size and the scale factor
    (population / measured calls): stratum total ~= scale * measured result.
"""
import argparse


def read_calls(fname):
    header = []
    calls = []  # (expanded, call_id, text)
    block = []
    exp = cid = None
    with open(fname) as f:
        for line in f:
            if line.startswith("CALL "):
                parts = line.split()
                cid, exp = int(parts[1]), int(parts[5])
                block = [line]
            elif block:
                block.append(line)
                if line.startswith("END"):
                    calls.append((exp, cid, "".join(block)))
                    block = []
            else:
                header.append(line)
    return "".join(header), calls


def print_stats(exps):
    n = len(exps)
    exps = sorted(exps)
    total = sum(exps)
    q = lambda p: exps[min(n - 1, int(p * n))]
    print("calls=%d total_expanded=%d mean=%.0f  p50=%d p90=%d p99=%d max=%d"
          % (n, total, total / n, q(0.5), q(0.9), q(0.99), exps[-1]))
    desc = exps[::-1]
    for frac in (0.01, 0.05, 0.10, 0.25, 0.50):
        k = max(1, int(round(frac * n)))
        print("heaviest %3.0f%% of calls (%4d calls) hold %5.1f%% of all expansions"
              % (frac * 100, k, 100.0 * sum(desc[:k]) / total))
    for target in (0.5, 0.8, 0.9):
        acc = 0
        for i, e in enumerate(desc, 1):
            acc += e
            if acc >= target * total:
                print("%d heaviest calls already hold %.0f%% of all expansions" % (i, 100 * target))
                break
    for thr in (1000, 5000, 10000, 30000, 60000):
        sel = [e for e in exps if e >= thr]
        print("calls with >= %5d expansions: %4d (%.1f%% of calls, %.1f%% of expansions)"
              % (thr, len(sel), 100.0 * len(sel) / n, 100.0 * sum(sel) / total))


def stratify(header, calls, bounds, per, warm, prefix):
    edges = [0] + bounds + [float("inf")]
    total_all = sum(c[0] for c in calls)
    lines = ["# stratum lo hi population pop_expanded warm_calls roi_calls roi_expanded scale"]
    est_total = 0.0
    for s in range(len(edges) - 1):
        lo, hi = edges[s], edges[s + 1]
        members = sorted((c for c in calls if lo <= c[0] < hi), key=lambda c: (c[0], c[1]))
        pop = len(members)
        if pop == 0:
            continue
        m = min(pop, per + warm)
        picks = [members[int((i + 0.5) * pop / m)] for i in range(m)]
        w = min(warm, m - 1)
        warm_idx = set(int((i + 0.5) * m / w) for i in range(w)) if w > 0 else set()
        wcalls = sorted((picks[i] for i in warm_idx), key=lambda c: c[1])
        rcalls = sorted((picks[i] for i in range(m) if i not in warm_idx), key=lambda c: c[1])
        scale = pop / len(rcalls)
        pop_exp = sum(c[0] for c in members)
        roi_exp = sum(c[0] for c in rcalls)
        est_total += scale * roi_exp
        fname = "%s%d.trace" % (prefix, s)
        with open(fname, "w") as f:
            f.write(header)
            for _, _, text in wcalls + rcalls:
                f.write(text)
        hi_s = "inf" if hi == float("inf") else str(hi)
        lines.append("%d %d %s %d %d %d %d %d %.4f" % (s, lo, hi_s, pop, pop_exp, len(wcalls), len(rcalls), roi_exp, scale))
        print("stratum %d [%d,%s): population %4d calls (%.1f%% of expansions); %d warm-up + %d measured calls "
              "(%d expansions measured), scale x%.1f -> %s"
              % (s, lo, hi_s, pop, 100.0 * pop_exp / total_all, len(wcalls), len(rcalls), roi_exp, scale, fname))
    with open(prefix + ".manifest", "w") as f:
        f.write("\n".join(lines) + "\n")
    print("sample-based estimate of total expansions: %.0f (actual %d, error %+.1f%%)"
          % (est_total, total_all, 100.0 * (est_total - total_all) / total_all))
    print("manifest: %s.manifest" % prefix)


def single_file(header, calls, a):
    n = len(calls)
    total = sum(c[0] for c in calls)
    if a.every > 0:
        if a.by_size:
            order = sorted(range(n), key=lambda i: (calls[i][0], i))
            sample = [calls[i] for i in sorted(order[a.offset::a.every])]
        else:
            sample = calls[a.offset::a.every]
        warm, roi = sample[:a.warm], sample[a.warm:]
        what = "every %d-th call%s from index %d" % (a.every, " in size order" if a.by_size else "", a.offset)
    else:
        lo = a.window_start
        if lo - a.warm < 0 or lo + a.window_len > n:
            raise SystemExit("window [%d-%d warm-up, %d+%d) does not fit in %d calls" % (lo, a.warm, lo, a.window_len, n))
        warm, roi = calls[lo - a.warm:lo], calls[lo:lo + a.window_len]
        what = "calls %d..%d (+%d warm-up calls before)" % (lo, lo + a.window_len - 1, a.warm)
    with open(a.out_trace, "w") as f:
        f.write(header)
        for _, _, text in warm + roi:
            f.write(text)
    roi_exp = sum(c[0] for c in roi)
    heavy = sum(1 for c in roi if c[0] >= 20000)
    print("%s: %d warm-up + %d measured calls (%d with >= 20000 expansions), %d measured expansions "
          "(%.1f%% of the run; expansion scale x%.1f)"
          % (what, len(warm), len(roi), heavy, roi_exp, 100.0 * roi_exp / total, total / roi_exp))
    print("replay with: --warmup %d --iters %d" % (len(warm), len(roi)))
    print("wrote %s" % a.out_trace)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("full_trace")
    ap.add_argument("out_trace", nargs="?")
    ap.add_argument("--top", type=int, default=0, help="keep the N heaviest calls")
    ap.add_argument("--min-expanded", type=int, default=0, help="keep calls with at least this many expansions")
    ap.add_argument("--stats-only", action="store_true")
    ap.add_argument("--stratify", metavar="PREFIX", help="write PREFIX<k>.trace per stratum + PREFIX.manifest")
    ap.add_argument("--bounds", default="1000,5000,20000", help="comma-separated stratum boundaries (expanded nodes)")
    ap.add_argument("--per", type=int, default=6, help="measured calls per stratum")
    ap.add_argument("--warm", type=int, default=2, help="warm-up calls (per stratum, or at the start of the file)")
    ap.add_argument("--every", type=int, default=0, help="single file: keep every K-th call in original order")
    ap.add_argument("--offset", type=int, default=0, help="with --every: index of the first kept call")
    ap.add_argument("--by-size", action="store_true", help="with --every: pick every K-th call in size order")
    ap.add_argument("--window-start", type=int, default=-1, help="single file: first measured call of a window")
    ap.add_argument("--window-len", type=int, default=0, help="with --window-start: number of measured calls")
    a = ap.parse_args()

    header, calls = read_calls(a.full_trace)
    if not calls:
        raise SystemExit("no calls in trace")
    print_stats([c[0] for c in calls])
    if a.stats_only:
        return
    if a.stratify:
        stratify(header, calls, [int(x) for x in a.bounds.split(",")], a.per, a.warm, a.stratify)
        return
    if not a.out_trace:
        raise SystemExit("OUT_TRACE (or --stratify PREFIX) required unless --stats-only")
    if a.every > 0 or a.window_start >= 0:
        single_file(header, calls, a)
        return

    chosen = [c for c in calls if c[0] >= a.min_expanded]
    if a.top > 0:
        chosen = sorted(chosen, key=lambda c: (-c[0], c[1]))[: a.top]
    chosen.sort(key=lambda c: c[1])
    with open(a.out_trace, "w") as f:
        f.write(header)
        for _, _, text in chosen:
            f.write(text)
    print("wrote %d calls (%d expansions) to %s" % (len(chosen), sum(c[0] for c in chosen), a.out_trace))


if __name__ == "__main__":
    main()
