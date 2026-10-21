#!/usr/bin/env bash
set -u
source ~/eecbs_env.sh
NATIVE="$REPO/kernel/build/lowlevel_kernel"
RESULTS="$REPO/runs/gem5_attrib/ALL"; mkdir -p "$RESULTS"
NP=$(nproc); JOBS="${JOBS:-$NP}"; [ "$JOBS" -gt 4 ] && JOBS=4
STAGGER="${STAGGER:-15}"
GARGS="--cpu-type=TimingSimpleCPU --caches --l2cache"   # Timing: 5x faster, 归因与O3一致

TABLE=(
"maze4|maze-32-32-4.map|maze-32-32-4-random-1.scen|kernel/traces/maze4_bs32_o7.trace"
"empty|empty-32-32.map|empty-32-32-random-1.scen|kernel/traces/empty_bs32_o7.trace"
"room32|room-32-32-4.map|room-32-32-4-random-1.scen|kernel/traces/room32_bs32_o7.trace"
"room64|room-64-64-8.map|room-64-64-8-random-1.scen|kernel/traces/room64_bs32_o7.trace"
"warehouse|warehouse-10-20-10-2-1.map|warehouse-10-20-10-2-1-random-1.scen|kernel/traces/warehouse_bs16_o13.trace"
"random|random-32-32-20.map|random-32-32-20-random-1.scen|kernel/traces/random_bs16_o9.trace"
"den312d|den312d.map|den312d-random-1.scen|kernel/traces/den312d_bs128_o50.trace"
"ost003d|ost003d.map|ost003d-random-1.scen|kernel/traces/ost003d_bs8_o3.trace"
"maze128_10|maze-128-128-10.map|maze-128-128-10-random-1.scen|kernel/traces/maze128_10_bs32_o7.trace"
"berlin|Berlin_1_256.map|Berlin_1_256-random-1.scen|kernel/traces/berlin_bs8_o3.trace"
"boston|Boston_0_256.map|Boston_0_256-random-1.scen|kernel/traces/boston_bs8_o1.trace"
"paris|Paris_1_256.map|Paris_1_256-random-1.scen|kernel/traces/paris_bs8_o3.trace"
"brc202d|brc202d.map|brc202d-random-1.scen|kernel/traces/brc202d_bs32_o18.trace"
# "randomA|random-32-32-20.map|random-32-32-20-random-1.scen|kernel/traces/randomA_bs32_o7.trace"  # scen待确认
)

declare -A SETUP; declare -A PID; declare -A START; todo=()
echo "== Phase 1: 串行测 setup（perf，不抢 PMU）=="
for row in "${TABLE[@]}"; do
  IFS='|' read -r name map scen trace <<< "$row"
  [ -f "$RESULTS/$name/pool_attrib_roi.txt" ] && { echo "[$name] 已完成，跳过"; continue; }
  if [ ! -f "$REPO/$map" ] || [ ! -f "$REPO/$scen" ] || [ ! -f "$REPO/$trace" ]; then echo "[$name] 缺输入，跳过"; continue; fi
  ins=$(perf stat -x, -e cpu_core/instructions/u "$NATIVE" --map "$REPO/$map" --scen "$REPO/$scen" --trace "$REPO/$trace" --warmup 0 --iters 0 2>&1 | awk -F, '/instructions/{print $1; exit}')
  [[ "$ins" =~ ^[0-9]+$ ]] || ins=$(perf stat -x, -e instructions:u "$NATIVE" --map "$REPO/$map" --scen "$REPO/$scen" --trace "$REPO/$trace" --warmup 0 --iters 0 2>&1 | awk -F, '/instructions/{print $1; exit}')
  if [[ "$ins" =~ ^[0-9]+$ ]]; then SETUP[$name]=$(( ins*95/100 )); echo "[$name] setup≈$ins ff=${SETUP[$name]}"; else SETUP[$name]=18500000; echo "[$name] perf测不到→默认ff=18500000"; fi
  todo+=("$row")
done

run_map() {
  local name="$1" map="$2" scen="$3" trace="$4" ff="$5"
  local wd="$RESULTS/$name/wd"; mkdir -p "$wd"; cd "$wd"; rm -f eecbs_pool_ranges.txt pool_attrib_roi.txt
  python3 "$REPO/kernel/run_gem5.py" --single "$REPO/$trace" --warm 2 \
    --bin "$POOLBIN" --native-bin "$NATIVE" --setup-insts "$ff" \
    --map "$REPO/$map" --scen "$REPO/$scen" --outroot "$RESULTS/$name" \
    --gem5-args "$GARGS" > "$RESULTS/$name/run.log" 2>&1
  [ -f pool_attrib_roi.txt ] && cp pool_attrib_roi.txt "$RESULTS/$name/"
}

echo "== Phase 2: 并行跑 Timing（并发 $JOBS，错开 ${STAGGER}s）=="
pending=("${todo[@]}")
while true; do
  running=$(jobs -rp | wc -l)
  if [ "$running" -lt "$JOBS" ] && [ "${#pending[@]}" -gt 0 ]; then
    row="${pending[0]}"; pending=("${pending[@]:1}"); IFS='|' read -r name map scen trace <<< "$row"
    START[$name]=$SECONDS; run_map "$name" "$map" "$scen" "$trace" "${SETUP[$name]}" & PID[$name]=$!
    sleep "$STAGGER"; continue
  fi
  clear 2>/dev/null || true
  echo "===== 进度 $(date +%H:%M:%S)  并发 $JOBS  待启动 ${#pending[@]} ====="
  for row in "${TABLE[@]}"; do
    IFS='|' read -r name map scen trace <<< "$row"
    if [ -f "$RESULTS/$name/pool_attrib_roi.txt" ]; then printf "  %-12s ✅ done\n" "$name"
    elif [ -n "${PID[$name]:-}" ] && kill -0 "${PID[$name]}" 2>/dev/null; then printf "  %-12s ⏳ %dm\n" "$name" $(( (SECONDS-${START[$name]})/60 ))
    elif [ -n "${PID[$name]:-}" ]; then printf "  %-12s ⚠ 结束无结果,看 run.log\n" "$name"
    else printf "  %-12s · 待跑\n" "$name"; fi
  done
  [ "${#pending[@]}" -eq 0 ] && [ "$(jobs -rp | wc -l)" -eq 0 ] && break
  sleep 15
done
wait
echo "== 汇总（system.l2）==" | tee "$RESULTS/summary.txt"
for row in "${TABLE[@]}"; do
  IFS='|' read -r name map scen trace <<< "$row"
  [ -f "$RESULTS/$name/pool_attrib_roi.txt" ] || continue
  { echo "### $name"; python3 "$REPO/kernel/parse_pool_attrib.py" "$RESULTS/$name/pool_attrib_roi.txt" system.l2; echo; } | tee -a "$RESULTS/summary.txt"
done
echo "完成，汇总见 $RESULTS/summary.txt"
