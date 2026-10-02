# Low-level search kernel

Standalone driver that calls the unmodified `SpaceTimeAStar::findSuboptimalPath` (the part of
EECBS that eats ~98% of the runtime) so it can be profiled and simulated without running the
whole solver.

## Workflow: record real calls, replay the heaviest ones

1. **Build a tracing eecbs** in a separate build dir. `-DKERNEL_TRACE` enables a hook in
   `ECBS::findPathForSingleAgent`; the normal build does not contain it, so existing
   baselines are unaffected.
   ```bash
   mkdir -p build-trace && cd build-trace
   cmake -DCMAKE_CXX_FLAGS=-DKERNEL_TRACE .. && make -j8
   ```
2. **Record** one full run (same arguments as the baseline). Nothing is written unless
   `EECBS_TRACE_FILE` is set.
   ```bash
   EECBS_TRACE_FILE=/tmp/m2_full.trace ./eecbs -m maze-32-32-2.map -a maze-32-32-2-random-1.scen \
       -k 70 -t 60 --suboptimality=1.18
   ```
3. **Look at the distribution, then pick the heavy calls.**
   ```bash
   python3 kernel/select_trace.py /tmp/m2_full.trace --stats-only
   mkdir -p kernel/traces
   python3 kernel/select_trace.py /tmp/m2_full.trace kernel/traces/maze-32-32-2.trace --top 20
   ```
4. **Replay** (build the kernel first: `cd kernel && mkdir -p build && cd build && cmake .. && make`).
   ```bash
   ./lowlevel_kernel --map ../../maze-32-32-2.map --scen ../../maze-32-32-2-random-1.scen \
       --trace ../traces/maze-32-32-2.trace --iters 200
   ```
   The output ends with `replay/recorded=<ratio>`: expansions of the replay divided by the
   expansions the real run spent on the same calls. It should be close to 1 (not exactly 1:
   the `rand() % 2` tie-break stream differs from the real run).

## Synthetic mode (no `--trace`)

Plans every agent once, then replans against hand-made blocking constraints
(`--constraints`, `--block-len`, `--w`). Useful for controlled sweeps (`sweep.sh`), not for
claiming representativeness.

## gem5

`-DKERNEL_STATIC=ON` for a static binary (SE mode); `-DKERNEL_M5OPS_DIR=~/gem5` brackets the
measured loop with `m5_reset_stats()` / `m5_dump_stats()`.
