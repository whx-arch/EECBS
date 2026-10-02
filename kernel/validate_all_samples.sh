#!/usr/bin/env bash
# Validate by-size-32 samples against full traces using perf hardware counters.
# Run from the repo root: bash kernel/validate_all_samples.sh 2>&1 | tee kernel/traces/validation.log
#
# Prerequisites: native kernel binary at kernel/build/lowlevel_kernel
set -euo pipefail

BIN=kernel/build/lowlevel_kernel
SELECT=kernel/select_trace.py
SAMPLE_PERF=kernel/sample_perf.py
TRACEDIR=kernel/traces

if [ ! -x "$BIN" ]; then
  echo "ERROR: native kernel not found at $BIN"
  echo "Build it: cd kernel && mkdir -p build && cd build && cmake .. && make -j8"
  exit 1
fi

# alias  map  scen  full_trace  sample_trace
declare -a MAPS=(
  "maze2       maze-32-32-2.map              maze-32-32-2-random-1.scen              m2_full.trace              bs32_o7.trace"
  "random      random-32-32-20.map           random-32-32-20-random-1.scen           random_full.trace          random_bs32_o7.trace"
  "warehouse   warehouse-10-20-10-2-1.map    warehouse-10-20-10-2-1-random-1.scen    warehouse_full.trace       warehouse_bs32_o7.trace"
  "empty       empty-32-32.map               empty-32-32-random-1.scen               empty_full.trace           empty_bs32_o7.trace"
  "room32      room-32-32-4.map              room-32-32-4-random-1.scen              room32_full.trace          room32_bs32_o7.trace"
  "den312d     den312d.map                   den312d-random-1.scen                   den312d_full.trace         den312d_bs32_o7.trace"
  "maze4       maze-32-32-4.map              maze-32-32-4-random-1.scen              maze4_full.trace           maze4_bs32_o7.trace"
  "room64      room-64-64-8.map              room-64-64-8-random-1.scen              room64_full.trace          room64_bs32_o7.trace"
  "brc202d     brc202d.map                   brc202d-random-1.scen                   brc202d_full.trace         brc202d_bs32_o7.trace"
  "berlin      Berlin_1_256.map              Berlin_1_256-random-1.scen              berlin_full.trace          berlin_bs32_o7.trace"
  "boston       Boston_0_256.map              Boston_0_256-random-1.scen              boston_full.trace           boston_bs32_o7.trace"
  "paris       Paris_1_256.map               Paris_1_256-random-1.scen               paris_full.trace           paris_bs32_o7.trace"
)

for entry in "${MAPS[@]}"; do
  read -r alias mapf scenf full sample <<< "$entry"
  full_path="$TRACEDIR/$full"
  sample_path="$TRACEDIR/$sample"

  if [ ! -f "$full_path" ]; then
    echo "=== [$alias] SKIP: $full_path not found ==="
    echo ""
    continue
  fi
  if [ ! -f "$sample_path" ]; then
    echo "=== [$alias] SKIP: $sample_path not found ==="
    echo ""
    continue
  fi

  echo "=========================================="
  echo "[$alias] full=$full  sample=$sample"
  echo "=========================================="
  python3 "$SAMPLE_PERF" --bin "$BIN" --map "$mapf" --scen "$scenf" \
    --full-trace "$full_path" --warm 2 "$sample_path"
  echo ""
done
