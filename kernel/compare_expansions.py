#!/usr/bin/env python3
"""Is the difference between a replay and the real run explained by random tie-breaking alone?

Input: files written by `lowlevel_kernel --trace T --per-call FILE` (columns: call index, found
flag, expanded nodes in the real run, expanded nodes in this replay). Give two or more files,
made with different --seed values on the same trace.

Prints, for calls that FOUND a path (not-found calls are exhaustive searches and must match
exactly):
  * real run vs replay of each file
  * replay vs replay for every pair of files
If the replay-vs-replay deviations look like the real-vs-replay ones, the real run is just
another random draw of the tie-breaking and nothing else differs.

usage: compare_expansions.py seed1.txt seed2.txt [seed3.txt ...]
"""
import itertools
import sys


def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            idx, found, rec, rep = line.split()
            rows.append((int(idx), int(found), int(rec), int(rep)))
    return rows


def describe(label, pairs):
    """pairs: list of (reference, other) expansion counts."""
    devs = sorted(abs(b - a) / max(1, a) for a, b in pairs)
    n = len(devs)
    tot_a = sum(a for a, _ in pairs)
    tot_b = sum(b for _, b in pairs)
    abs_sum = sum(abs(b - a) for a, b in pairs)
    q = lambda p: devs[min(n - 1, int(p * n))]
    print("%-34s differ %4d/%d | |dev| median %5.1f%% p90 %6.1f%% p99 %7.1f%% max %7.1f%% | "
          "signed total %+.2f%%, sum|diff| %.2f%% of total"
          % (label, sum(1 for a, b in pairs if a != b), n, 100 * q(0.5), 100 * q(0.9), 100 * q(0.99),
             100 * devs[-1], 100.0 * (tot_b - tot_a) / tot_a, 100.0 * abs_sum / tot_a))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    files = sys.argv[1:]
    data = [load(f) for f in files]
    nf = [[r for r in d if r[1] == 0] for d in data]
    bad = sum(1 for d in nf for r in d if r[2] != r[3])
    print("not-found (exhaustive) calls: %d per file, expansions differing from the real run: %d"
          % (len(nf[0]), bad))
    found = [[r for r in d if r[1] == 1] for d in data]
    for f, d in zip(files, found):
        describe("real vs " + f, [(r[2], r[3]) for r in d])
    for (fa, da), (fb, db) in itertools.combinations(zip(files, found), 2):
        describe("%s vs %s" % (fa, fb), [(ra[3], rb[3]) for ra, rb in zip(da, db)])


if __name__ == "__main__":
    main()
