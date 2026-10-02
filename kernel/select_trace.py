#!/usr/bin/env python3
"""Pick the heaviest low-level calls out of a full trace written by a -DKERNEL_TRACE build.

usage: select_trace.py FULL_TRACE OUT_TRACE [--top N] [--min-expanded X]
                                            [--stats-only]

Keeps the header, then the N calls with the largest recorded `expanded` (ties: earlier call
first), written back in their original order. --stats-only just prints the distribution of
expanded nodes per call, which is what you want to look at before choosing N / X.
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("full_trace")
    ap.add_argument("out_trace", nargs="?")
    ap.add_argument("--top", type=int, default=0, help="keep the N heaviest calls")
    ap.add_argument("--min-expanded", type=int, default=0, help="keep calls with at least this many expansions")
    ap.add_argument("--stats-only", action="store_true")
    a = ap.parse_args()

    header, calls = read_calls(a.full_trace)
    exps = sorted(c[0] for c in calls)
    n = len(exps)
    if n == 0:
        raise SystemExit("no calls in trace")
    q = lambda p: exps[min(n - 1, int(p * n))]
    print("calls=%d total_expanded=%d mean=%.0f  p50=%d p90=%d p99=%d max=%d"
          % (n, sum(exps), sum(exps) / n, q(0.5), q(0.9), q(0.99), exps[-1]))
    if a.stats_only:
        total = sum(exps)
        desc = sorted(exps, reverse=True)
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
        for thr in (10000, 30000, 60000):
            big = [e for e in exps if e >= thr]
            print("calls with >= %5d expansions: %4d (%.1f%% of expansions)"
                  % (thr, len(big), 100.0 * sum(big) / total))
        return
    if not a.out_trace:
        raise SystemExit("OUT_TRACE required unless --stats-only")

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
