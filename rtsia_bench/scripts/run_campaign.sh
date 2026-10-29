#!/usr/bin/env bash
# Run a whole block of experiments described in a plan file, one run after another
# (stress-ng and rt-app stressors), with what long campaigns need:
#   - the plan is checked BEFORE starting (stressor names, isolation, rt-app installed),
#     so a typo does not fail runs in the middle of the night;
#   - sudo is asked ONCE at the start and kept alive for the whole campaign
#     (needed by prio / pin_prio and by rt-app SCHED_FIFO threads);
#   - before each run, leftover stressors (rt-app, stress-ng) of a crashed run are stopped.
#
# Plan file: one configuration per line, 7 columns, '#' starts a comment.
#   systems      stress          level  isolation        reps  duration_s  freq_hz
#   semif        rtapp_fifo60    4      none             3     180         2
#   semif        rtapp_fifo60    4      prio80           3     180         2
#   semif,gemma  rtapp_burst60   4      pin_prio80@semif 3     300         2
#
# stress:    none | stress-ng types (cpu_matrix, cpu_fft, mem_stream, mem_vm, cache_l1,
#            sched_switch, io_hdd) | rt-app types (rtapp_other, rtapp_fifo[P],
#            rtapp_heavy[P], rtapp_burst[P]; P = rt-app priority, default 60)
# level:     stress-ng workers or rt-app threads
# isolation: none | pin | prio[P] | pin_prio[P], optionally @semif / @gemma
#            (P = model priority, default 50; e.g. prio80, pin_prio80@gemma)
#
# Usage:
#   scripts/run_campaign.sh plans/b8_rtapp.plan [--csv campagna.csv] [--shuffle] [--skip-done] [--dry-run]
#
#   --csv NAME    decision CSV in OUT_DIR (same for the whole campaign)   [campagna.csv]
#   --shuffle     random run order (reduces time trends, as in a DOE)
#   --skip-done   skip runs already in runs_summary.csv (resume after an interruption)
#   --dry-run     only check the plan, list the runs and the estimated time
#
# A failed run is logged and the campaign continues with the next one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR=${OUT_DIR:-$HOME/RTSIASarnataroTafuri/risultati}
RTAPP=${RTAPP:-rt-app}
PLAN=""; CSV=campagna.csv; SHUFFLE=false; SKIP_DONE=false; DRY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv) CSV=$2; shift 2 ;;
    --shuffle) SHUFFLE=true; shift ;;
    --skip-done) SKIP_DONE=true; shift ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    -*) echo "Unknown option: $1"; exit 1 ;;
    *) PLAN=$1; shift ;;
  esac
done
[[ -f "$PLAN" ]] || { echo "Plan file not found: $PLAN"; exit 1; }

# ---------------------------------------------------------------- read and check the plan
STRESS_NG_RE='^(cpu_matrix|cpu_fft|mem_stream|mem_vm|cache_l1|sched_switch|io_hdd)$'
RTAPP_RE='^rtapp_(other|(fifo|heavy|burst)([0-9]{1,2})?)$'
ISO_RE='^(none|pin|(prio|pin_prio)([0-9]{1,2})?)(@(semif|gemma|qwen))?$'
NEED_SUDO=false; NEED_RTAPP=false; NEED_STRESSNG=false; ERRORS=0
RUNS=(); LINE_NO=0
while IFS= read -r line || [[ -n $line ]]; do
  LINE_NO=$((LINE_NO + 1))
  read -r systems stress level isolation reps duration freq _ <<< "$line"
  [[ -z "${systems:-}" || "$systems" == \#* ]] && continue
  bad() { echo "Plan line $LINE_NO: $1"; echo "    $line"; ERRORS=$((ERRORS + 1)); }
  [[ -n "${freq:-}" ]] || { bad "incomplete (7 columns needed)"; continue; }
  [[ "$systems" =~ ^(semif|gemma|qwen)(,(semif|gemma|qwen))*$ ]] || bad "unknown system in '$systems'"
  if [[ $stress == none ]]; then :
  elif [[ "$stress" =~ $STRESS_NG_RE ]]; then NEED_STRESSNG=true
  elif [[ "$stress" =~ $RTAPP_RE ]]; then
    NEED_RTAPP=true
    [[ $stress != rtapp_other ]] && NEED_SUDO=true
  else bad "unknown stress '$stress'"; fi
  [[ "$level" =~ ^[0-9]+$ ]] || bad "level must be a number: '$level'"
  [[ $stress != none && "$level" =~ ^[0-9]+$ && $level -lt 1 ]] && bad "level must be >= 1 with stress $stress"
  if [[ "$isolation" =~ $ISO_RE ]]; then
    [[ $isolation == *prio* ]] && NEED_SUDO=true
    target=${BASH_REMATCH[5]}
    [[ -n $target && ",$systems," != *",$target,"* ]] && bad "isolation target '$target' is not in '$systems'"
  else
    bad "unknown isolation '$isolation' (none, pin, prio[P], pin_prio[P], optional @system)"
  fi
  [[ "$reps" =~ ^[0-9]+$ && "$duration" =~ ^[0-9]+$ && "$freq" =~ ^[0-9.]+$ ]] || bad "reps, duration_s and freq_hz must be numbers"
  for ((r = 1; r <= reps; r++)); do
    RUNS+=("$systems $stress $level $isolation $r $duration $freq")
  done
done < "$PLAN"
[[ $ERRORS -eq 0 ]] || { echo "== $ERRORS error(s) in $PLAN: nothing was run."; exit 1; }
[[ ${#RUNS[@]} -gt 0 ]] || { echo "No runs in $PLAN"; exit 1; }
if [[ $SHUFFLE == true ]]; then
  mapfile -t RUNS < <(printf '%s\n' "${RUNS[@]}" | shuf)
fi

key() {  # same config_key format as run_experiment.sh
  local systems=$1 stress=$2 level=$3 isolation=$4 rep=$5 freq=$6
  [[ $stress == none ]] && level=0
  isolation=${isolation//@/_}   # pin_prio80@semif -> pin_prio80_semif
  local sep=""; [[ $stress =~ [0-9]$ ]] && sep=x   # rtapp_fifo60 + 4 -> rtapp_fifo60x4
  echo "${systems//,/+}_f${freq}_${stress}${sep}${level}_${isolation}_r${rep}"
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
echo "   needs: sudo=$NEED_SUDO rt-app=$NEED_RTAPP stress-ng=$NEED_STRESSNG"

# ---------------------------------------------------------------- tools
MISSING=0
if [[ $NEED_RTAPP == true ]] && ! command -v "$RTAPP" > /dev/null; then
  echo "   rt-app not found: sudo apt install rt-app (or set RTAPP=/path/to/rt-app)"; MISSING=1
fi
if [[ $NEED_STRESSNG == true ]] && ! command -v stress-ng > /dev/null; then
  echo "   stress-ng not found: sudo apt install stress-ng"; MISSING=1
fi

if [[ $DRY == true ]]; then
  i=0
  for run in "${RUNS[@]}"; do
    i=$((i + 1)); read -r systems stress level isolation rep duration freq <<< "$run"
    k=$(key "$systems" "$stress" "$level" "$isolation" "$rep" "$freq")
    status=""; [[ $SKIP_DONE == true ]] && done_before "$k" && status=" (done, will skip)"
    printf '%3d  %s%s\n' "$i" "$k" "$status"
  done
  [[ $MISSING -eq 0 ]] || echo "== WARNING: install the missing tools before the real campaign"
  exit 0
fi
[[ $MISSING -eq 0 ]] || exit 1

# ---------------------------------------------------------------- sudo, asked once
KEEPALIVE_PID=""
stop_keepalive() { [[ -n $KEEPALIVE_PID ]] && kill "$KEEPALIVE_PID" 2> /dev/null; true; }
trap stop_keepalive EXIT
if [[ $NEED_SUDO == true ]]; then
  echo "   this plan needs sudo (real-time priorities): enter the password once"
  sudo -v || { echo "sudo failed: campaign not started"; exit 1; }
  # Refresh the sudo timestamp every minute until the campaign ends.
  ( while true; do sudo -n true; sleep 60; done ) > /dev/null 2>&1 &
  KEEPALIVE_PID=$!
fi

# Stop stressors left over by a crashed run (they would disturb the next one).
clean_leftovers() {
  local left=""
  pgrep -x rt-app > /dev/null && left+=" rt-app"
  pgrep -x stress-ng > /dev/null && left+=" stress-ng"
  [[ -z $left ]] && return
  echo "   leftover stressors found:$left -> stopping them" | tee -a "$CLOG"
  sudo -n pkill -TERM -x rt-app 2> /dev/null || pkill -TERM -x rt-app 2> /dev/null
  pkill -TERM -x stress-ng 2> /dev/null
  sleep 2
  sudo -n pkill -KILL -x rt-app 2> /dev/null || pkill -KILL -x rt-app 2> /dev/null
  pkill -KILL -x stress-ng 2> /dev/null
  true
}

# ---------------------------------------------------------------- run
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
  clean_leftovers
  echo "[$i/${#RUNS[@]}] $(date +%H:%M:%S) start $k" | tee -a "$CLOG"
  if RTAPP="$RTAPP" "$SCRIPT_DIR/run_experiment.sh" --systems "$systems" --stress "$stress" --level "$level" \
       --isolation "$isolation" --rep "$rep" --duration "$duration" --freq "$freq" \
       --csv "$CSV" >> "$CLOG" 2>&1; then
    OK=$((OK + 1)); echo "[$i/${#RUNS[@]}] $(date +%H:%M:%S) ok" | tee -a "$CLOG"
  else
    FAILED=$((FAILED + 1)); echo "[$i/${#RUNS[@]}] $(date +%H:%M:%S) FAILED (see $CLOG)" | tee -a "$CLOG"
  fi
done
clean_leftovers
echo "== Campaign finished: $OK ok, $FAILED failed, $SKIPPED skipped" | tee -a "$CLOG"
