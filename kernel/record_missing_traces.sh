#!/usr/bin/env bash
# Record kernel traces for the 3 maps missing from the original batch.
# Run from the repo root: bash kernel/record_missing_traces.sh 2>&1 | tee kernel/traces/missing_recording.log
#
# Prerequisites (same as record_all_traces.sh):
#   cmake -S . -B build-trace -DCMAKE_CXX_FLAGS=-DKERNEL_TRACE
#   cmake --build build-trace -j8
#   Native kernel: cd kernel && mkdir -p build && cd build && cmake .. && make -j8
set -euo pipefail

TRACE_BIN=./build-trace/eecbs
TRACEDIR=kernel/traces
SELECT=kernel/select_trace.py
SAMPLE_PERF=kernel/sample_perf.py
NATIVE_BIN=kernel/build/lowlevel_kernel
EVERY=32
OFFSET=7

mkdir -p "$TRACEDIR"

# map_alias  map_file  scen_file  k  suboptimality
declare -a MAPS=(
  # random A: timeout baseline (k=200, ~62s runtime, trace will be large)
  "randomA     random-32-32-20.map              random-32-32-20-random-1.scen           200  1.2"
  # maze-128-128-10: large wide maze, 2x2 matrix 4th cell, cache sweep
  "maze128_10  maze-128-128-10.map              maze-128-128-10-random-1.scen           800  1.2"
  # ost003d: game map #2, heterogeneity validation vs den312d
  "ost003d     ost003d.map                      ost003d-random-1.scen                   400  1.2"
)

echo "=== Recording 3 missing traces ==="
echo ""

for entry in "${MAPS[@]}"; do
  read -r alias mapf scenf k sub <<< "$entry"
  raw="$TRACEDIR/${alias}_full.trace"
  sample="$TRACEDIR/${alias}_bs${EVERY}_o${OFFSET}.trace"

  echo "=========================================="
  echo "[$alias] map=$mapf k=$k s=$sub"
  echo "=========================================="

  # Step 1: Record full trace
  if [ -f "$raw" ]; then
    echo "  full trace exists, skipping recording"
  else
    echo "  recording full trace..."
    EECBS_TRACE_FILE="$raw" "$TRACE_BIN" \
      -m "$mapf" -a "$scenf" -k "$k" -t 60 --suboptimality="$sub" \
      || echo "  WARNING: eecbs exited non-zero (timeout is OK for randomA)"
  fi

  # Step 2: Show distribution
  echo "  --- distribution ---"
  python3 "$SELECT" "$raw" --stats-only

  # Step 3: Generate by-size-32 sample
  if [ -f "$sample" ]; then
    echo "  sample trace exists, skipping"
  else
    echo "  generating by-size-$EVERY sample..."
    python3 "$SELECT" "$raw" "$sample" --every "$EVERY" --offset "$OFFSET" --by-size --warm 2
  fi

  # Step 4: Initial perf validation (sample vs full)
  if [ -x "$NATIVE_BIN" ]; then
    echo "  --- perf validation (sample vs full) ---"
    python3 "$SAMPLE_PERF" --bin "$NATIVE_BIN" --map "$mapf" --scen "$scenf" \
      --full-trace "$raw" --warm 2 "$sample"
  else
    echo "  WARNING: native kernel not found at $NATIVE_BIN, skipping perf validation"
    echo "  Build it: cd kernel && mkdir -p build && cd build && cmake .. && make -j8"
  fi

  echo ""
done

echo "=== Done. New traces: ==="
for entry in "${MAPS[@]}"; do
  read -r alias _ _ _ _ <<< "$entry"
  ls -lh "$TRACEDIR/${alias}_full.trace" "$TRACEDIR/${alias}_bs${EVERY}_o${OFFSET}.trace" 2>/dev/null || true
done
