#!/usr/bin/env bash
# Extended map cache sweep: run the same cache configs on 3 additional maps
# to broaden coverage for the paper.
# Run from the repo root:  bash kernel/sweep_extended_maps.sh
set -euo pipefail

MAX_JOBS=4
OUTBASE=runs/extended_cache_sweep
RUN_GEM5="python3 kernel/run_gem5.py"
LOGDIR="$OUTBASE/logs"
mkdir -p "$LOGDIR"

# 3 additional maps with different characteristics:
#   den312d    — large game map, high call count (12928 calls), different topology
#   maze128_10 — large wide maze (128×128, 10 agents), memory stress test
#   berlin     — city map, control group (225 calls, small workload)
declare -a MAPS=(
  "den312d     den312d.map                    den312d-random-1.scen              kernel/traces/den312d_bs128_o50.trace    2"
  "maze128_10  maze-128-128-10.map            maze-128-128-10-random-1.scen      kernel/traces/maze128_10_bs32_o7.trace   2"
  "berlin      Berlin_1_256.map               Berlin_1_256-random-1.scen         kernel/traces/berlin_bs8_o3.trace        2"
)

# Same configs as the core cache sweep (skip line_32B — always fails on O3)
declare -a CONFIGS=(
  "baseline         "
  "l1d_16kB         --l1d_size=16kB"
  "l1d_32kB         --l1d_size=32kB"
  "l1d_128kB        --l1d_size=128kB"
  "l2_256kB         --l2_size=256kB"
  "l2_512kB         --l2_size=512kB"
  "l2_1MB           --l2_size=1MB"
  "l2_4MB           --l2_size=4MB"
  "line_128B        --cacheline_size=128"
)

declare -a JOB_CMDS=()
declare -a JOB_NAMES=()

for map_entry in "${MAPS[@]}"; do
  read -r alias mapf scenf trace warm <<< "$map_entry"

  # verify trace exists before queueing
  if [ ! -f "$trace" ]; then
    echo "[ERROR] Trace not found: $trace — skipping $alias"
    echo "        Re-record with: bash kernel/record_all_traces.sh (or record_missing_traces.sh)"
    continue
  fi

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
echo "  Extended map sweep: $TOTAL jobs, max $MAX_JOBS parallel"
echo "  Output: $OUTBASE/<map>/<config>/"
echo "============================================"
echo ""

if [ "$TOTAL" -eq 0 ]; then
  echo "All jobs already completed. Nothing to do."
  exit 0
fi

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
  echo "        log: $logfile"
  eval "$cmd" > "$logfile" 2>&1 &
  PIDS+=("$!")
  PID_NAMES+=("$name")
}

wait_for_slot() {
  while [ ${#PIDS[@]} -ge $MAX_JOBS ]; do
    for i in "${!PIDS[@]}"; do
      if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
        wait "${PIDS[$i]}" && true
        local rc=$?
        DONE=$((DONE + 1))
        if [ $rc -eq 0 ]; then
          echo "[ OK ] ($DONE/$TOTAL) ${PID_NAMES[$i]}"
        else
          echo "[FAIL] ($DONE/$TOTAL) ${PID_NAMES[$i]} (exit $rc) — see $LOGDIR/${PID_NAMES[$i]}.log"
          FAILED=$((FAILED + 1))
        fi
        unset 'PIDS[i]'; unset 'PID_NAMES[i]'
        PIDS=("${PIDS[@]}"); PID_NAMES=("${PID_NAMES[@]}")
        return
      fi
    done
    sleep 5
  done
}

START_TIME=$(date +%s)
while [ $NEXT -lt $TOTAL ]; do
  wait_for_slot
  start_job $NEXT
  NEXT=$((NEXT + 1))
  sleep 15
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

SUMMARY_CSV="$OUTBASE/extended_cache_results.csv"
echo "map,config,insts,cycles,CPI,cond_predicted,cond_incorrect,branch_miss_rate,MPKI,dcache_misses,dcache_accesses,dcache_miss_rate,l2cache_misses,l2cache_accesses,l2cache_miss_rate" > "$SUMMARY_CSV"

for map_entry in "${MAPS[@]}"; do
  read -r alias _ _ _ _ <<< "$map_entry"
  for cfg_entry in "${CONFIGS[@]}"; do
    cfg_name=$(echo "$cfg_entry" | awk '{print $1}')
    json="$OUTBASE/${alias}/${cfg_name}/summary.json"
    [ ! -f "$json" ] && continue
    python3 -c "
import json
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
