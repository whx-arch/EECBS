#!/usr/bin/env bash
# Branch predictor sweep (control group for cache study).
# Run from the repo root:  bash kernel/sweep_bp.sh
#
# Purpose: show that memory-dominated maps are insensitive to BP choice,
# while branch-dominated maps respond.  Baseline (TournamentBP) is reused
# from cache_sweep/<map>/baseline/summary.json — not re-run here.
set -euo pipefail

MAX_JOBS=3
OUTBASE=runs/bp_sweep
RUN_GEM5="python3 kernel/run_gem5.py"
LOGDIR="$OUTBASE/logs"
mkdir -p "$LOGDIR"

# ── Map definitions ──────────────────────────────────────────────────
declare -a MAPS=(
  "maze2    maze-32-32-2.map    maze-32-32-2-random-1.scen    kernel/traces/bs32_o7.trace           2"
  "brc202d  brc202d.map         brc202d-random-1.scen         kernel/traces/brc202d_bs32_o18.trace  2"
  "room64   room-64-64-8.map    room-64-64-8-random-1.scen    kernel/traces/room64_bs32_o7.trace    2"
)

# ── Branch predictor configurations ─────────────────────────────────
# TournamentBP is gem5 default — baseline already exists in cache_sweep.
# These are the NEW predictors to test.
declare -a BPS=(
  "LocalBP"
  "BiModeBP"
  "LTAGE"
)

# ── Job queue ────────────────────────────────────────────────────────
declare -a JOB_CMDS=()
declare -a JOB_NAMES=()

for map_entry in "${MAPS[@]}"; do
  read -r alias mapf scenf trace warm <<< "$map_entry"
  for bp in "${BPS[@]}"; do
    outroot="$OUTBASE/${alias}/${bp}"
    job_name="${alias}__${bp}"

    if [ -f "$outroot/summary.json" ]; then
      echo "[SKIP] $job_name — already has summary.json"
      continue
    fi

    cmd="$RUN_GEM5 --single $trace --map $mapf --scen $scenf"
    cmd="$cmd --warm $warm --outroot $outroot"
    cmd="$cmd --gem5-args \"--cpu-type=DerivO3CPU --caches --l2cache\""
    cmd="$cmd --cond-bp $bp"
    cmd="$cmd --auto-setup"

    JOB_CMDS+=("$cmd")
    JOB_NAMES+=("$job_name")
  done
done

TOTAL=${#JOB_CMDS[@]}
echo "============================================"
echo "  BP sweep: $TOTAL jobs, max $MAX_JOBS parallel"
echo "  Output: $OUTBASE/<map>/<bp>/"
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
echo "  BP sweep complete: $DONE/$TOTAL jobs"
echo "  Failed: $FAILED"
echo "  Wall time: ${ELAPSED} minutes"
echo "============================================"

# ── Collect results CSV ──────────────────────────────────────────────
# Include TournamentBP baseline from cache_sweep
SUMMARY_CSV="$OUTBASE/all_results.csv"
echo "map,bp,insts,cycles,CPI,cond_predicted,cond_incorrect,branch_miss_rate,MPKI" > "$SUMMARY_CSV"

for map_entry in "${MAPS[@]}"; do
  read -r alias _ _ _ _ <<< "$map_entry"

  # TournamentBP baseline from cache_sweep
  json="runs/cache_sweep/${alias}/baseline/summary.json"
  if [ -f "$json" ]; then
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
print(f'$alias,TournamentBP,{insts:.0f},{cycles:.0f},{cpi:.4f},{cp:.0f},{ci:.0f},{bmr:.2f},{mpki:.2f}')
" 2>/dev/null || echo "$alias,TournamentBP,ERROR"
  fi

  # New predictors
  for bp in "${BPS[@]}"; do
    json="$OUTBASE/${alias}/${bp}/summary.json"
    if [ ! -f "$json" ]; then
      continue
    fi
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
print(f'$alias,$bp,{insts:.0f},{cycles:.0f},{cpi:.4f},{cp:.0f},{ci:.0f},{bmr:.2f},{mpki:.2f}')
" 2>/dev/null || echo "$alias,$bp,ERROR"
  done
done >> "$SUMMARY_CSV"

echo "Results CSV: $SUMMARY_CSV"
