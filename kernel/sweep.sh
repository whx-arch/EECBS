#!/usr/bin/env bash
# Sweep the kernel's constraint-pattern knobs and print how big each low-level search gets.
# usage: bash sweep.sh MAP SCEN AGENTS W [ITERS]      (run from kernel/build)
# env:   KERNEL_BIN=path/to/lowlevel_kernel   (default ./lowlevel_kernel)
set -u
bin=${KERNEL_BIN:-./lowlevel_kernel}
map=$1; scen=$2; k=$3; w=$4; iters=${5:-100}

printf '%-12s %-10s %12s %12s %7s %9s %9s\n' constraints block-len exp/call gen/call empty wall_s ms/call
for c in 3 10 30 60; do
  for b in 2 4 8; do
    out=$(timeout 120 "$bin" --map "$map" --scen "$scen" --agents "$k" --w "$w" \
          --iters "$iters" --constraints "$c" --block-len "$b" 2>/dev/null) || {
      printf '%-12s %-10s %s\n' "$c" "$b" "(timeout >120s or failed)"; continue; }
    echo "$out" | awk -v c="$c" -v b="$b" -v n="$iters" '{
      for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] }
      sub("s$", "", v["wall"])
      printf "%-12s %-10s %12.0f %12.0f %7s %9.3f %9.3f\n", c, b,
             v["expanded"] / n, v["generated"] / n, v["empty"], v["wall"], 1000 * v["wall"] / n }'
  done
done
