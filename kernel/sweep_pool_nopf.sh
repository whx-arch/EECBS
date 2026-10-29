#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sweep_pool_nopf.sh
#
# Purpose: isolate the *pooling-only* effect on L2 miss / cycles.
#   We run ONLY the POOL binary, no prefetcher, O3, at L2 = 512kB (main) plus
#   256kB / 2MB (sensitivity). The ORIGINAL (non-pool) no_pf O3 numbers already
#   exist in results/all_results.csv (cache sweep: l2_512kB / l2_256kB / baseline),
#   so we do NOT re-run the original here. At the end we subtract the two to get
#   the pooling net effect.
#
#   Pooling effect = pool no_pf  (this script)  -  original no_pf  (all_results.csv)
#
# Prereqs:  source ~/eecbs_env.sh   (sets REPO, POOLBIN, GEM5)
# Run from anywhere (script cd's into $REPO). Example:
#   source ~/eecbs_env.sh && bash "$REPO/kernel/sweep_pool_nopf.sh"
#
# Notes:
#   * Reuses the existing original cache-sweep cells (single run) as the baseline,
#     per the agreed "don't re-run the original" plan. For a final paper claim the
#     overlapping cells would be re-run with error bars; this first pass reuses them.
#   * O3 is slow (~250 KIPS). MAX_JOBS keeps a few in flight; tune below.
# ---------------------------------------------------------------------------
set -uo pipefail

# ── Resolve environment ────────────────────────────────────────────────────
: "${REPO:?set REPO via: source ~/eecbs_env.sh}"
: "${POOLBIN:?set POOLBIN via: source ~/eecbs_env.sh}"
GEM5_BIN="${GEM5:-$HOME/gem5}/build/X86/gem5.opt"
NATIVE_BIN="${NATIVE_BIN:-kernel/build/lowlevel_kernel}"   # original kernel, for expanded cross-check
ORIG_CSV="${ORIG_CSV:-results/all_results.csv}"            # original no_pf cache-sweep data (reused, not re-run)

MAX_JOBS="${MAX_JOBS:-4}"            # concurrent gem5 processes (matches earlier sweeps)
STAGGER_SECS="${STAGGER_SECS:-15}"   # min gap between launches: lets each --auto-setup
                                     # native-perf measurement run alone (avoid PMU contention)
REDRAW_SECS="${REDRAW_SECS:-3}"      # dashboard refresh interval
OUTBASE="runs/pool_nopf"

cd "$REPO" || { echo "cannot cd to REPO=$REPO"; exit 1; }
if [ ! -x "$POOLBIN" ]; then echo "POOLBIN not executable: $POOLBIN"; exit 1; fi
if [ ! -x "$GEM5_BIN" ]; then echo "gem5 not found: $GEM5_BIN"; exit 1; fi
mkdir -p "$OUTBASE/logs"

# ── Map table:  alias  map  scen  trace  warm ──────────────────────────────
declare -a MAPS=(
  "maze2    maze-32-32-2.map   maze-32-32-2-random-1.scen   kernel/traces/bs32_o7.trace          2"
  "maze4    maze-32-32-4.map   maze-32-32-4-random-1.scen   kernel/traces/maze4_bs32_o7.trace    2"
  "brc202d  brc202d.map        brc202d-random-1.scen        kernel/traces/brc202d_bs32_o18.trace 2"
  "room64   room-64-64-8.map   room-64-64-8-random-1.scen   kernel/traces/room64_bs32_o7.trace   2"
)

# ── L2 sizes:  label  gem5-size-flag  original-config-name-in-all_results ──
# (2MB is the gem5 default → no flag → original cell is named "baseline")
declare -a L2S=(
  "512kB  --l2_size=512kB  l2_512kB"
  "256kB  --l2_size=256kB  l2_256kB"
  "2MB    _NONE_           baseline"
)

# ── Build job list ─────────────────────────────────────────────────────────
declare -a J_NAME=() J_CMD=() J_LOG=() J_OUT=()
for m in "${MAPS[@]}"; do
  read -r alias mapf scenf trace warm <<< "$m"
  for l in "${L2S[@]}"; do
    read -r l2label l2flag l2orig <<< "$l"
    [ "$l2flag" = "_NONE_" ] && l2flag=""
    name="${alias}__${l2label}"
    out="$OUTBASE/${alias}/${l2label}"
    log="$OUTBASE/logs/${name}.log"
    gem5_args="--cpu-type=DerivO3CPU --caches --l2cache $l2flag"
    cmd="python3 kernel/run_gem5.py --single $trace --warm $warm"
    cmd="$cmd --bin \"$POOLBIN\" --native-bin \"$NATIVE_BIN\""
    cmd="$cmd --map $mapf --scen $scenf --outroot \"$out\""
    cmd="$cmd --gem5 \"$GEM5_BIN\""
    cmd="$cmd --gem5-args \"$gem5_args\" --auto-setup"
    J_NAME+=("$name"); J_CMD+=("$cmd"); J_LOG+=("$log"); J_OUT+=("$out")
  done
done
TOTAL=${#J_NAME[@]}

# ── Per-job runtime state ───────────────────────────────────────────────────
declare -a ST=()      # PENDING | RUNNING | OK | FAIL
declare -a PID=()     # pid while running, else ""
declare -a T0=()      # start epoch
declare -a T1=()      # end epoch
for ((i=0;i<TOTAL;i++)); do ST[i]="PENDING"; PID[i]=""; T0[i]=0; T1[i]=0; done

hhmmss() { local s=$1; printf "%02d:%02d" $((s/60)) $((s%60)); }
lastline() { # last non-empty line of a log, trimmed to width
  [ -f "$1" ] || { echo ""; return; }
  tail -n 40 "$1" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-72
}

draw() {
  local now done_ run_ fail_ i bar filled
  now=$(date +%s); done_=0; run_=0; fail_=0
  for ((i=0;i<TOTAL;i++)); do
    case "${ST[i]}" in OK|FAIL) done_=$((done_+1));; RUNNING) run_=$((run_+1));; esac
    [ "${ST[i]}" = "FAIL" ] && fail_=$((fail_+1))
  done
  printf '\033[H\033[J'   # cursor home + clear screen
  echo   "  POOL no_pf sweep (O3)   —   pooling-only effect"
  echo   "  gem5=$GEM5_BIN"
  echo   "  bin =$POOLBIN"
  echo   "  ------------------------------------------------------------------------"
  for ((i=0;i<TOTAL;i++)); do
    local tag el
    case "${ST[i]}" in
      RUNNING) el=$(hhmmss $((now-T0[i]))); tag="▶ RUN  $el";;
      OK)      el=$(hhmmss $((T1[i]-T0[i]))); tag="✓ OK   $el";;
      FAIL)    el=$(hhmmss $((T1[i]-T0[i]))); tag="✗ FAIL $el";;
      *)       tag="· wait     ";;
    esac
    if [ "${ST[i]}" = "RUNNING" ]; then
      printf "  %-18s %-12s  %s\n" "${J_NAME[i]}" "$tag" "$(lastline "${J_LOG[i]}")"
    else
      printf "  %-18s %-12s\n" "${J_NAME[i]}" "$tag"
    fi
  done
  echo   "  ------------------------------------------------------------------------"
  # progress bar
  bar=""; filled=$(( done_*30/TOTAL ))
  for ((i=0;i<30;i++)); do if [ $i -lt $filled ]; then bar="$bar#"; else bar="$bar-"; fi; done
  printf "  [%s] %d/%d done  (%d running, %d failed)   elapsed %s\n" \
         "$bar" "$done_" "$TOTAL" "$run_" "$fail_" "$(hhmmss $((now-WALL0)))"
}

# ── Scheduler loop ──────────────────────────────────────────────────────────
WALL0=$(date +%s)
LAST_LAUNCH=0            # epoch of the most recent job start (for staggering)
printf '\033[2J'
while :; do
  # reap finished
  for ((i=0;i<TOTAL;i++)); do
    if [ "${ST[i]}" = "RUNNING" ] && ! kill -0 "${PID[i]}" 2>/dev/null; then
      wait "${PID[i]}"; rc=$?
      T1[i]=$(date +%s)
      if [ $rc -eq 0 ]; then ST[i]="OK"; else ST[i]="FAIL"; fi
      PID[i]=""
    fi
  done
  # launch AT MOST ONE job per tick, and only after STAGGER_SECS since the last
  # start, so overlapping --auto-setup native-perf measurements don't fight for
  # the host PMU. Slots keep filling one-by-one up to MAX_JOBS.
  running=0; for ((i=0;i<TOTAL;i++)); do [ "${ST[i]}" = "RUNNING" ] && running=$((running+1)); done
  now=$(date +%s)
  if [ $running -lt $MAX_JOBS ] && [ $((now-LAST_LAUNCH)) -ge $STAGGER_SECS ]; then
    for ((i=0;i<TOTAL;i++)); do
      if [ "${ST[i]}" = "PENDING" ]; then
        ST[i]="RUNNING"; T0[i]=$now; LAST_LAUNCH=$now
        ( eval "${J_CMD[i]}" ) > "${J_LOG[i]}" 2>&1 &
        PID[i]=$!
        break
      fi
    done
  fi
  draw
  # done?
  rem=0; for ((i=0;i<TOTAL;i++)); do case "${ST[i]}" in PENDING|RUNNING) rem=$((rem+1));; esac; done
  [ $rem -eq 0 ] && break
  sleep "$REDRAW_SECS"
done
draw
echo

# ── Collect pool results → CSV ──────────────────────────────────────────────
POOL_CSV="$OUTBASE/pool_nopf_results.csv"
echo "map,l2,cycles,CPI,l2cache_misses,l2cache_accesses,l2cache_miss_rate,insts" > "$POOL_CSV"
for m in "${MAPS[@]}"; do
  read -r alias _ _ _ _ <<< "$m"
  for l in "${L2S[@]}"; do
    read -r l2label _ _ <<< "$l"
    json="$OUTBASE/${alias}/${l2label}/summary.json"
    [ -f "$json" ] || continue
    python3 -c "
import json
d=json.load(open('$json'))
ins=d.get('insts',0); cyc=d.get('cycles',0)
l2m=d.get('l2cache_misses',d.get('l2_misses',0)); l2a=d.get('l2cache_accesses',d.get('l2_accesses',0))
print('$alias,$l2label,%d,%.4f,%d,%d,%.2f,%d'%(cyc, (cyc/ins if ins else 0), l2m, l2a, (100*l2m/l2a if l2a else 0), ins))
" 2>/dev/null || echo "$alias,$l2label,ERROR"
  done
done >> "$POOL_CSV"

echo "Pool CSV: $POOL_CSV"
echo

# ── Pooling net effect = pool  minus  original (reused from all_results.csv) ─
echo "================  POOLING NET EFFECT  (pool no_pf  vs  original no_pf)  ================"
python3 - "$POOL_CSV" "$ORIG_CSV" <<'PY'
import sys, csv
pool_csv, orig_csv = sys.argv[1], sys.argv[2]
# original config name per l2 label
orig_cfg = {"512kB":"l2_512kB", "256kB":"l2_256kB", "2MB":"baseline"}

def load(path, keyfn):
    out={}
    try:
        for r in csv.DictReader(open(path)):
            out[keyfn(r)]=r
    except FileNotFoundError:
        pass
    return out

pool = load(pool_csv, lambda r:(r["map"], r["l2"]))
orig = load(orig_csv, lambda r:(r["map"], r["config"]))

hdr = ("map","L2","orig cyc","pool cyc","Δcyc%","orig L2miss%","pool L2miss%","Δmiss(pp)")
print("  %-8s %-6s %12s %12s %8s %12s %12s %10s" % hdr)
print("  " + "-"*86)
for (mp,l2) in sorted(pool):
    p = pool[(mp,l2)]
    ocfg = orig_cfg.get(l2)
    o = orig.get((mp,ocfg)) if ocfg else None
    pc = float(p["cycles"]); pm = float(p["l2cache_miss_rate"])
    if o:
        oc = float(o["cycles"]); om = float(o["l2cache_miss_rate"])
        dcyc = 100*(pc-oc)/oc if oc else 0
        print("  %-8s %-6s %12.0f %12.0f %+7.2f%% %11.2f%% %11.2f%% %+9.2f" %
              (mp, l2, oc, pc, dcyc, om, pm, pm-om))
    else:
        print("  %-8s %-6s %12s %12.0f %8s %12s %11.2f%% %10s  (no original cell)" %
              (mp, l2, "—", pc, "—", "—", pm, "—"))
print()
print("  Reading: Δcyc% < 0  => pooling is FASTER (fewer cycles). Δmiss(pp) < 0 => fewer L2 misses.")
print("  Original cells are single-run (cache sweep); pool cells single-run here.")
print("  For a paper claim, re-run both sides with error bars (noise floor ~0.15-0.7%).")
PY
echo "======================================================================================="
