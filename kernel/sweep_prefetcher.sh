#!/usr/bin/env bash
# Prefetcher sweep for gem5 kernel experiments.
# Validates §5.2 hypothesis: pointer-chasing (maze2) vs sequential (brc202d)
# respond differently to hardware prefetching.
#
# Run from the repo root:  bash kernel/sweep_prefetcher.sh
set -euo pipefail

MAX_JOBS=4
OUTBASE=runs/prefetcher_sweep
RUN_GEM5="python3 kernel/run_gem5.py"
LOGDIR="$OUTBASE/logs"
mkdir -p "$LOGDIR"

# ── Map definitions (same as cache sweep) ────────────────────────────
declare -a MAPS=(
  "maze2    maze-32-32-2.map    maze-32-32-2-random-1.scen    kernel/traces/bs32_o7.trace           2"
  "maze4    maze-32-32-4.map    maze-32-32-4-random-1.scen    kernel/traces/maze4_bs32_o7.trace     2"
  "brc202d  brc202d.map         brc202d-random-1.scen         kernel/traces/brc202d_bs32_o18.trace  2"
  "room64   room-64-64-8.map    room-64-64-8-random-1.scen    kernel/traces/room64_bs32_o7.trace    2"
)

# ── Prefetcher configurations ───────────────────────────────────────
# Base: --cpu-type=DerivO3CPU --caches --l2cache (no prefetcher by default)
declare -a CONFIGS=(
  # no prefetcher (control — same as cache sweep baseline)
  "no_pf            "

  # Stride prefetcher on L2: detects strided access patterns
  # Hypothesis: helps brc202d (sequential resize), not maze2 (pointer chasing)
  "stride_l2        --l2-hwp-type=StridePrefetcher"

  # Tagged prefetcher on L2: simple next-line prefetch on miss
  "tagged_l2        --l2-hwp-type=TaggedPrefetcher"
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
echo "  Prefetcher sweep: $TOTAL jobs, max $MAX_JOBS parallel"
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
  while [ ${#PIDS[@]} -ge $MAX_JOBS ]; do
    for i in "${!PIDS[@]}"; do
      if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
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

# ── Collect results into CSV ─────────────────────────────────────────
SUMMARY_CSV="$OUTBASE/prefetcher_results.csv"
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
