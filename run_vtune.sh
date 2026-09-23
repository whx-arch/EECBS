#!/usr/bin/env bash
# Profile the unmodified EECBS solver on an Intel x86-64 Linux machine.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir="$script_dir/upstream"
build_dir="$script_dir/build-vtune"
result_root="$script_dir/vtune-results"
map_file="$source_dir/random-32-32-20.map"
scen_file="$source_dir/random-32-32-20-random-1.scen"
agents=50
cutoff=60
bound=1.2
analysis=hotspots
sipp=false
jobs=4
vtune_bin=${VTUNE_BIN:-vtune}

usage() {
    cat <<'EOF'
Usage: ./run_vtune.sh [options]

Options:
  --map FILE           MovingAI .map file (default: upstream example)
  --scen FILE          MovingAI .scen file (default: upstream example)
  --agents N           Use the first N scenario rows (default: 50)
  --cutoff SECONDS     Solver time limit (default: 60)
  --bound W            EECBS suboptimality bound, W >= 1 (default: 1.2)
  --analysis TYPE      hotspots, uarch-exploration, or memory-access
                       (default: hotspots)
  --sipp true|false    Use SIPPS instead of space-time A* (default: false)
  --jobs N             Parallel build jobs (default: 4)
  --results DIR        Parent directory for VTune results
  --help               Show this help

Run on an Intel x86-64 Linux machine with CMake, Boost and the VTune CLI
available. If vtune is not on PATH, set VTUNE_BIN to its executable path.
Each invocation creates a new result directory and never overwrites a run.
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 2
}

while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --map|--scen|--agents|--cutoff|--bound|--analysis|--sipp|--jobs|--results)
            (($# >= 2)) || die "missing value for $1"
            option=$1
            value=$2
            shift 2
            case "$option" in
                --map) map_file=$value ;;
                --scen) scen_file=$value ;;
                --agents) agents=$value ;;
                --cutoff) cutoff=$value ;;
                --bound) bound=$value ;;
                --analysis) analysis=$value ;;
                --sipp) sipp=$value ;;
                --jobs) jobs=$value ;;
                --results) result_root=$value ;;
            esac
            ;;
        *) die "unknown option: $1" ;;
    esac
done

[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || \
    die 'this script requires an x86-64 Linux profiling target'
[[ $analysis == hotspots || $analysis == uarch-exploration || $analysis == memory-access ]] || \
    die 'analysis must be hotspots, uarch-exploration, or memory-access'
[[ $sipp == true || $sipp == false ]] || die 'sipp must be true or false'
[[ $agents =~ ^[1-9][0-9]*$ ]] || die 'agents must be a positive integer'
[[ $jobs =~ ^[1-9][0-9]*$ ]] || die 'jobs must be a positive integer'
[[ $cutoff =~ ^[0-9]+([.][0-9]+)?$ ]] || die 'cutoff must be a positive number'
[[ $bound =~ ^[0-9]+([.][0-9]+)?$ ]] || die 'bound must be a number >= 1'
awk -v x="$cutoff" 'BEGIN { exit !(x > 0) }' || die 'cutoff must be > 0'
awk -v x="$bound" 'BEGIN { exit !(x >= 1) }' || die 'bound must be >= 1'

for command in cmake awk realpath sha256sum; do
    command -v "$command" >/dev/null 2>&1 || die "$command is not installed"
done
command -v "$vtune_bin" >/dev/null 2>&1 || \
    die 'vtune not found; source the Intel oneAPI environment or set VTUNE_BIN'
[[ -f $map_file ]] || die "map file not found: $map_file"
[[ -f $scen_file ]] || die "scenario file not found: $scen_file"
[[ -f $source_dir/CMakeLists.txt ]] || die "EECBS source not found: $source_dir"

map_file=$(realpath "$map_file")
scen_file=$(realpath "$scen_file")
mkdir -p "$build_dir" "$result_root"
result_root=$(realpath "$result_root")

# Keep the solver optimized while retaining symbols and source line information.
# The policy override makes upstream's CMake 2.6 declaration work with CMake 4.
cmake -S "$source_dir" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS_RELEASE='-O3 -DNDEBUG -g' \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$build_dir" --parallel "$jobs"
solver="$build_dir/eecbs"
[[ -x $solver ]] || die "solver executable not found: $solver"

run_dir=$(mktemp -d "$result_root/$analysis-k$agents-XXXXXXXX")
vtune_result="$run_dir/vtune"
stats_file="$run_dir/solver.csv"
if command -v lscpu >/dev/null 2>&1; then
    lscpu > "$run_dir/cpu-info.txt"
fi

solver_args=(
    "$solver"
    -m "$map_file"
    -a "$scen_file"
    -k "$agents"
    -t "$cutoff"
    --suboptimality="$bound"
    --highLevelSolver=EES
    --lowLevelSolver=true
    --sipp="$sipp"
    -s 0
    -o "$stats_file"
)

{
    printf 'source_commit='
    git -C "$source_dir" rev-parse HEAD 2>/dev/null || printf 'unknown\n'
    printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'analysis=%s\nmap=%s\nscenario=%s\nagents=%s\ncutoff=%s\nbound=%s\nsipp=%s\n' \
        "$analysis" "$map_file" "$scen_file" "$agents" "$cutoff" "$bound" "$sipp"
    printf 'map_sha256='; sha256sum "$map_file"
    printf 'scenario_sha256='; sha256sum "$scen_file"
    printf 'host='; uname -a
    compiler_version=$(c++ --version)
    printf 'compiler=%s\n' "${compiler_version%%$'\n'*}"
    printf 'command='; printf '%q ' "${solver_args[@]}"; printf '\n'
} > "$run_dir/run-info.txt"

printf 'Collecting %s into %s\n' "$analysis" "$vtune_result"
if ! "$vtune_bin" -collect "$analysis" -result-dir "$vtune_result" \
    -- "${solver_args[@]}" > "$run_dir/collection.log" 2>&1; then
    cat "$run_dir/collection.log" >&2
    die "VTune collection failed; files retained in $run_dir"
fi

if [[ ! -s $stats_file ]] || \
   ! awk -F, 'NR == 2 { found = 1; if ($6 ~ /^[0-9]+$/) solved = 1 }
              END { exit !(found && solved) }' "$stats_file"; then
    die "solver did not report a solution; inspect $run_dir/collection.log and $stats_file"
fi

"$vtune_bin" -report summary -result-dir "$vtune_result" \
    -report-output "$run_dir/summary.txt"
if [[ $analysis == hotspots ]]; then
    "$vtune_bin" -report hotspots -result-dir "$vtune_result" \
        -format csv -csv-delimiter comma \
        -report-output "$run_dir/hotspots.csv"
fi

printf 'Done. Results: %s\n' "$run_dir"
printf 'Solver statistics: %s\n' "$stats_file"
printf 'VTune summary: %s\n' "$run_dir/summary.txt"
