#!/usr/bin/env bash
# L3 cache sweep: add L3 to gem5 model to match real Raptor Lake (30MB L3).
# Tests how L3 buffers L2 misses and whether L2 sensitivity changes.
# Run from the repo root:  bash kernel/sweep_l3.sh
set -euo pipefail

MAX_JOBS=4
OUTBASE=runs/l3_sweep
RUN_GEM5="python3 kernel/run_gem5.py"
LOGDIR="$OUTBASE/logs"
mkdir -p "$LOGDIR"

declare -a MAPS=(
  "maze2    maze-32-32-2.map    maze-32-32-2-random-1.scen    kernel/traces/bs32_o7.trace           2"
  "maze4    maze-32-32-4.map    maze-32-32-4-random-1.scen    kernel/traces/maze4_bs32_o7.trace     2"
  "brc202d  brc202d.map         brc202d-random-1.scen         kernel/traces/brc202d_bs32_o18.trace  2"
  "room64   room-64-64-8.map    room-64-64-8-random-1.scen    kernel/traces/room64_bs32_o7.trace    2"
)

# Configs: vary L3 size, and cross with L2 size to see interaction
# gem5 deprecated se.py supports --l3cache --l3_size --l3_assoc
declare -a CONFIGS=(
  # baseline (no L3, same as existing cache sweep)
  "no_l3            "

  # L3 size sweep with default L2=2MB
  "l3_8MB           --l3cache --l3_size=8MB"
  "l3_16MB          --l3cache --l3_size=16MB"
  "l3_32MB          --l3cache --l3_size=32MB"

  # L2=256kB + L3: does L3 compensate for tiny L2?
  "l2_256kB_l3_32MB --l2_size=256kB --l3cache --l3_size=32MB"

  # L2=4MB + L3: combined effect
  "l2_4MB_l3_32MB   --l2_size=4MB --l3cache --l3_size=32MB"
)

# ── Verify gem5 supports --l3cache before queueing ───────────────────
GEM5_BIN="$HOME/gem5/build/X86/gem5.opt"
SE_PY="$HOME/gem5/configs/deprecated/example/se.py"
if ! "$GEM5_BIN" "$SE_PY" --help 2>&1 | grep -q "l3cache"; then
  echo "ERROR: gem5 se.py does not support --l3cache."
  echo "You may need a newer gem5 build or a custom config script."
  exit 1
fi
echo "[CHECK] gem5 --l3cache support confirmed."
echo ""

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
echo "  L3 sweep: $TOTAL jobs, max $MAX_JOBS parallel"
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

SUMMARY_CSV="$OUTBASE/l3_results.csv"
echo "map,config,insts,cycles,CPI,cond_predicted,cond_incorrect,branch_miss_rate,MPKI,dcache_misses,dcache_accesses,dcache_miss_rate,l2cache_misses,l2cache_accesses,l2cache_miss_rate,l3cache_misses,l3cache_accesses,l3cache_miss_rate" > "$SUMMARY_CSV"

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
l3m = d.get('l3cache_misses', d.get('l3_misses', 0))
l3a = d.get('l3cache_accesses', d.get('l3_accesses', 0))
l3mr = 100*l3m/l3a if l3a else 0
print(f'$alias,$cfg_name,{insts:.0f},{cycles:.0f},{cpi:.4f},{cp:.0f},{ci:.0f},{bmr:.2f},{mpki:.2f},{dm:.0f},{da:.0f},{dmr:.2f},{l2m:.0f},{l2a:.0f},{l2mr:.2f},{l3m:.0f},{l3a:.0f},{l3mr:.2f}')
" 2>/dev/null || echo "$alias,$cfg_name,ERROR"
  done
done >> "$SUMMARY_CSV"

echo "Results CSV: $SUMMARY_CSV"
