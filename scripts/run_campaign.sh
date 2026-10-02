#!/usr/bin/env bash
# Run a whole block of experiments described in a plan file, one run after another.
#
# Plan file: one configuration per line, '#' starts a comment.
#   systems      stress        level  isolation  reps  duration_s  freq_hz
#   semif        none          0      none       5     180         2
#   gemma        cpu_matrix    4      pin_prio   3     300         2
#
# Usage:
#   scripts/run_campaign.sh plans/b1_baseline.plan [--csv campagna.csv] [--shuffle] [--skip-done] [--dry-run]
#
#   --csv NAME    decision CSV in OUT_DIR (same for the whole campaign)   [campagna.csv]
#   --shuffle     random run order (reduces time trends, as in a DOE)
#   --skip-done   skip runs already in runs_summary.csv (resume after an interruption)
#   --dry-run     only list the runs and the estimated time
#
# A failed run is logged and the campaign continues with the next one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR=${OUT_DIR:-$HOME/RTSIASarnataroTafuri/risultati}
PLAN=""; CSV=campagna.csv; SHUFFLE=false; SKIP_DONE=false; DRY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv) CSV=$2; shift 2 ;;
    --shuffle) SHUFFLE=true; shift ;;
    --skip-done) SKIP_DONE=true; shift ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    -*) echo "Unknown option: $1"; exit 1 ;;
    *) PLAN=$1; shift ;;
  esac
done
[[ -f "$PLAN" ]] || { echo "Plan file not found: $PLAN"; exit 1; }

# Expand the plan: one line per single run (repetitions unrolled).
RUNS=()
while read -r systems stress level isolation reps duration freq _; do
  [[ -z "${systems:-}" || "$systems" == \#* ]] && continue
  [[ -n "${freq:-}" ]] || { echo "Incomplete plan line: $systems $stress $level $isolation $reps $duration"; exit 1; }
  for ((r = 1; r <= reps; r++)); do
    RUNS+=("$systems $stress $level $isolation $r $duration $freq")
  done
done < "$PLAN"
[[ ${#RUNS[@]} -gt 0 ]] || { echo "No runs in $PLAN"; exit 1; }
if [[ $SHUFFLE == true ]]; then
  mapfile -t RUNS < <(printf '%s\n' "${RUNS[@]}" | shuf)
fi

key() {  # same config_key format as run_experiment.sh
  local systems=$1 stress=$2 level=$3 isolation=$4 rep=$5 freq=$6
  [[ $stress == none ]] && level=0
  echo "${systems//,/+}_f${freq}_${stress}${level}_${isolation}_r${rep}"
}
done_before() {
  [[ -s "$OUT_DIR/runs_summary.csv" ]] && grep -q ",$1," "$OUT_DIR/runs_summary.csv"
}

# Time estimate: stream + grace + fixed overhead (SemIf load/warm-up is the slow part).
TOTAL=0
for run in "${RUNS[@]}"; do
  read -r systems _ _ _ _ duration _ <<< "$run"
  overhead=30; [[ $systems == *semif* ]] && overhead=90
  TOTAL=$((TOTAL + duration + 15 + overhead))
done
echo "== Plan $PLAN: ${#RUNS[@]} runs, estimated $((TOTAL / 3600)) h $(((TOTAL % 3600) / 60)) min"

if [[ $DRY == true ]]; then
  i=0
  for run in "${RUNS[@]}"; do
    i=$((i + 1)); read -r systems stress level isolation rep duration freq <<< "$run"
    k=$(key "$systems" "$stress" "$level" "$isolation" "$rep" "$freq")
    status=""; [[ $SKIP_DONE == true ]] && done_before "$k" && status=" (done, will skip)"
    printf '%3d  %s%s\n' "$i" "$k" "$status"
  done
  exit 0
fi

mkdir -p "$OUT_DIR"
CLOG="$OUT_DIR/campaign_$(date +%Y%m%d_%H%M%S)_$(basename "$PLAN" .plan).log"
echo "   campaign log: $CLOG"
OK=0; FAILED=0; SKIPPED=0; i=0
for run in "${RUNS[@]}"; do
  i=$((i + 1)); read -r systems stress level isolation rep duration freq <<< "$run"
  k=$(key "$systems" "$stress" "$level" "$isolation" "$rep" "$freq")
  if [[ $SKIP_DONE == true ]] && done_before "$k"; then
    echo "[$i/${#RUNS[@]}] skip $k (already done)" | tee -a "$CLOG"; SKIPPED=$((SKIPPED + 1)); continue
  fi
  echo "[$i/${#RUNS[@]}] $(date +%H:%M:%S) start $k" | tee -a "$CLOG"
  if "$SCRIPT_DIR/run_experiment.sh" --systems "$systems" --stress "$stress" --level "$level" \
       --isolation "$isolation" --rep "$rep" --duration "$duration" --freq "$freq" \
       --csv "$CSV" >> "$CLOG" 2>&1; then
    OK=$((OK + 1)); echo "[$i/${#RUNS[@]}] $(date +%H:%M:%S) ok" | tee -a "$CLOG"
  else
    FAILED=$((FAILED + 1)); echo "[$i/${#RUNS[@]}] $(date +%H:%M:%S) FAILED (see $CLOG)" | tee -a "$CLOG"
  fi
done
echo "== Campaign finished: $OK ok, $FAILED failed, $SKIPPED skipped" | tee -a "$CLOG"
