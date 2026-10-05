#!/usr/bin/env bash
# Cache parameter sweep for gem5 kernel experiments.
# Run from the repo root:  bash kernel/sweep_cache.sh
#
# Manages up to MAX_JOBS parallel gem5 processes. When a slot frees up,
# the next queued job starts automatically. Each (map, config) pair gets
# its own output directory under runs/cache_sweep/.
set -euo pipefail

MAX_JOBS=4
OUTBASE=runs/cache_sweep
RUN_GEM5="python3 kernel/run_gem5.py"
LOGDIR="$OUTBASE/logs"
mkdir -p "$LOGDIR"

# ── Map definitions ──────────────────────────────────────────────────
# alias | map file | scen file | trace file | warm
declare -a MAPS=(
  "maze2    maze-32-32-2.map    maze-32-32-2-random-1.scen    kernel/traces/bs32_o7.trace           2"
  "maze4    maze-32-32-4.map    maze-32-32-4-random-1.scen    kernel/traces/maze4_bs32_o7.trace     2"
  "brc202d  brc202d.map         brc202d-random-1.scen         kernel/traces/brc202d_bs32_o18.trace  2"
  "room64   room-64-64-8.map    room-64-64-8-random-1.scen    kernel/traces/room64_bs32_o7.trace    2"
)

# ── Cache configurations to sweep ───────────────────────────────────
# config_name | extra gem5 args (appended to the base args)
# Base: --cpu-type=DerivO3CPU --caches --l2cache (L1D=64kB, L2=2MB, line=64B)
declare -a CONFIGS=(
  # baseline (default cache sizes)
  "baseline         "

  # L1D size sweep (keep L2=2MB, line=64)
  "l1d_16kB         --l1d_size=16kB"
  "l1d_32kB         --l1d_size=32kB"
  "l1d_128kB        --l1d_size=128kB"

  # L2 size sweep (keep L1D=64kB, line=64)
  "l2_256kB         --l2_size=256kB"
  "l2_512kB         --l2_size=512kB"
  "l2_1MB           --l2_size=1MB"
  "l2_4MB           --l2_size=4MB"

  # Cache line size sweep (keep L1D=64kB, L2=2MB)
  "line_32B         --cacheline_size=32"
  "line_128B        --cacheline_size=128"
)

# ── Job queue ────────────────────────────────────────────────────────
declare -a JOB_CMDS=()
declare -a JOB_NAMES=()

for map_entry in "${MAPS[@]}"; do
  read -r alias mapf scenf trace warm <<< "$map_entry"
  for cfg_entry in "${CONFIGS[@]}"; do
    cfg_name=$(echo "$cfg_entry" | awk '{print $1}')
    cfg_args=$(echo "$cfg_entry" | sed 's/^[^ ]* *//')

    outroot="$OUTBASE/${alias}/${cfg_name}"
    job_name="${alias}__${cfg_name}"

    # skip if summary.json already exists (completed run)
    if [ -f "$outroot/summary.json" ]; then
      echo "[SKIP] $job_name — already has summary.json"
      continue
    fi

    gem5_args="--cpu-type=DerivO3CPU --caches --l2cache $cfg_args"

    cmd="$RUN_GEM5 --single $trace --map $mapf --scen $scenf"
    cmd="$cmd --warm $warm --outroot $outroot"
    cmd="$cmd --gem5-args \"$gem5_args\""
    cmd="$cmd --auto-setup"

    JOB_CMDS+=("$cmd")
    JOB_NAMES+=("$job_name")
  done
done

TOTAL=${#JOB_CMDS[@]}
echo "============================================"
echo "  Cache sweep: $TOTAL jobs, max $MAX_JOBS parallel"
echo "  Output: $OUTBASE/<map>/<config>/"
echo "============================================"
echo ""

if [ "$TOTAL" -eq 0 ]; then
  echo "All jobs already completed. Nothing to do."
  exit 0
fi

# ── Parallel executor ────────────────────────────────────────────────
declare -a PIDS=()
declare -a PID_NAMES=()
NEXT=0
DONE=0
FAILED=0

start_job() {
  local idx=$1
  local name="${JOB_NAMES[$idx]}"
  local cmd="${JOB_CMDS[$idx]}"
  local logfile="$LOGDIR/${name}.log"

  echo "[START] ($((idx+1))/$TOTAL) $name"
  echo "        cmd: $cmd"
  echo "        log: $logfile"

  eval "$cmd" > "$logfile" 2>&1 &
  local pid=$!
  PIDS+=("$pid")
  PID_NAMES+=("$name")
}

wait_for_slot() {
  # Wait for any one child to finish, then remove it from the tracking arrays
  while [ ${#PIDS[@]} -ge $MAX_JOBS ]; do
    for i in "${!PIDS[@]}"; do
      if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
        # Process finished — check exit code
        wait "${PIDS[$i]}" && true
        local rc=$?
        local name="${PID_NAMES[$i]}"
        DONE=$((DONE + 1))
        if [ $rc -eq 0 ]; then
          echo "[ OK ] ($DONE/$TOTAL) $name"
        else
          echo "[FAIL] ($DONE/$TOTAL) $name (exit $rc) — see $LOGDIR/${name}.log"
          FAILED=$((FAILED + 1))
        fi
        unset 'PIDS[i]'
        unset 'PID_NAMES[i]'
        # Re-index arrays to remove gaps
        PIDS=("${PIDS[@]}")
        PID_NAMES=("${PID_NAMES[@]}")
        return
      fi
    done
    sleep 5
  done
}

# ── Main loop ────────────────────────────────────────────────────────
START_TIME=$(date +%s)

while [ $NEXT -lt $TOTAL ]; do
  wait_for_slot
  start_job $NEXT
  NEXT=$((NEXT + 1))
done

# Wait for remaining jobs
for i in "${!PIDS[@]}"; do
  wait "${PIDS[$i]}" && true
  local_rc=$?
  DONE=$((DONE + 1))
  if [ $local_rc -eq 0 ]; then
    echo "[ OK ] ($DONE/$TOTAL) ${PID_NAMES[$i]}"
  else
    echo "[FAIL] ($DONE/$TOTAL) ${PID_NAMES[$i]} (exit $local_rc)"
    FAILED=$((FAILED + 1))
  fi
done

END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))

echo ""
echo "============================================"
echo "  Sweep complete: $DONE/$TOTAL jobs"
echo "  Failed: $FAILED"
echo "  Wall time: ${ELAPSED} minutes"
echo "============================================"

# ── Collect all summaries into one CSV ───────────────────────────────
SUMMARY_CSV="$OUTBASE/all_results.csv"
echo "map,config,insts,cycles,CPI,cond_predicted,cond_incorrect,branch_miss_rate,MPKI,dcache_misses,dcache_accesses,dcache_miss_rate,l2cache_misses,l2cache_accesses,l2cache_miss_rate" > "$SUMMARY_CSV"

for map_entry in "${MAPS[@]}"; do
  read -r alias _ _ _ _ <<< "$map_entry"
  for cfg_entry in "${CONFIGS[@]}"; do
    cfg_name=$(echo "$cfg_entry" | awk '{print $1}')
    json="$OUTBASE/${alias}/${cfg_name}/summary.json"
    if [ ! -f "$json" ]; then
      continue
    fi
    python3 -c "
import json, sys
d = json.load(open('$json'))
insts = d.get('insts', 0)
cycles = d.get('cycles', 0)
cpi = cycles / insts if insts else 0
cp = d.get('cond_predicted', 0)
ci = d.get('cond_incorrect', 0)
bmr = 100*ci/cp if cp else 0
mpki = 1000*ci/insts if insts else 0
dm = d.get('dcache_misses', 0)
da = d.get('dcache_accesses', 0)
dmr = 100*dm/da if da else 0
l2m = d.get('l2cache_misses', d.get('l2_misses', 0))
l2a = d.get('l2cache_accesses', d.get('l2_accesses', 0))
l2mr = 100*l2m/l2a if l2a else 0
print(f'$alias,$cfg_name,{insts:.0f},{cycles:.0f},{cpi:.4f},{cp:.0f},{ci:.0f},{bmr:.2f},{mpki:.2f},{dm:.0f},{da:.0f},{dmr:.2f},{l2m:.0f},{l2a:.0f},{l2mr:.2f}')
" 2>/dev/null || echo "$alias,$cfg_name,ERROR"
  done
done >> "$SUMMARY_CSV"

echo "Results CSV: $SUMMARY_CSV"
echo "Per-run logs: $LOGDIR/"
echo "Per-run stats: $OUTBASE/<map>/<config>/single/roi_stats_summary.json"
