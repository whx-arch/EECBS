#!/usr/bin/env bash
# Record kernel traces for all target maps, then generate by-size-32 samples.
# Run from the repo root: bash kernel/record_all_traces.sh
#
# Prerequisites:
#   cmake -S . -B build-trace -DCMAKE_CXX_FLAGS=-DKERNEL_TRACE
#   cmake --build build-trace -j8
set -euo pipefail

TRACE_BIN=./build-trace/eecbs
TRACEDIR=kernel/traces
SELECT=kernel/select_trace.py
EVERY=32
OFFSET=7

mkdir -p "$TRACEDIR"

# map_alias  map_file  scen_file  k  suboptimality
declare -a MAPS=(
  # === BP sweep: 7 branch-dominated maps ===
  "random      random-32-32-20.map              random-32-32-20-random-1.scen           150  1.15"
  "warehouse   warehouse-10-20-10-2-1.map       warehouse-10-20-10-2-1-random-1.scen    500  1.2"
  "empty       empty-32-32.map                  empty-32-32-random-1.scen               325  1.2"
  "room32      room-32-32-4.map                 room-32-32-4-random-1.scen              100  1.2"
  "den312d     den312d.map                      den312d-random-1.scen                   250  1.2"
  "maze4       maze-32-32-4.map                 maze-32-32-4-random-1.scen               70  1.2"
  "room64      room-64-64-8.map                 room-64-64-8-random-1.scen              170  1.2"
  # === Cache sweep: memory-dominated (maze-32-32-2 already done) ===
  "maze128_2   maze-128-128-2.map               maze-128-128-2-random-1.scen             38  1.2"
  "brc202d     brc202d.map                      brc202d-random-1.scen                   800  1.2"
  # === Control group: city maps ===
  "berlin      Berlin_1_256.map                 Berlin_1_256-random-1.scen              800  1.2"
  "boston       Boston_0_256.map                 Boston_0_256-random-1.scen              800  1.2"
  "paris       Paris_1_256.map                  Paris_1_256-random-1.scen               800  1.2"
)

for entry in "${MAPS[@]}"; do
  read -r alias mapf scenf k sub <<< "$entry"
  raw="$TRACEDIR/${alias}_full.trace"
  sample="$TRACEDIR/${alias}_bs${EVERY}_o${OFFSET}.trace"

  echo "=========================================="
  echo "[$alias] map=$mapf k=$k s=$sub"
  echo "=========================================="

  # Step 1: Record full trace (skip if already exists)
  if [ -f "$raw" ]; then
    echo "  full trace exists, skipping recording"
  else
    echo "  recording..."
    EECBS_TRACE_FILE="$raw" "$TRACE_BIN" \
      -m "$mapf" -a "$scenf" -k "$k" -t 60 --suboptimality="$sub" \
      || echo "  WARNING: eecbs exited non-zero (timeout is OK)"
  fi

  # Step 2: Show distribution
  echo "  --- distribution ---"
  python3 "$SELECT" "$raw" --stats-only

  # Step 3: Generate by-size-32 sample (skip if exists)
  if [ -f "$sample" ]; then
    echo "  sample trace exists, skipping"
  else
    echo "  generating by-size-$EVERY sample..."
    python3 "$SELECT" "$raw" "$sample" --every "$EVERY" --offset "$OFFSET" --by-size --warm 2
  fi

  echo ""
done

echo "=== Done. All traces in $TRACEDIR/ ==="
ls -lh "$TRACEDIR"/*.trace
