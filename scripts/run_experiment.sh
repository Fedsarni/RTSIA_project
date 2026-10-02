#!/usr/bin/env bash
# Run ONE experiment end to end: start the nodes, apply isolation, start the stressor,
# stream sensor data for a fixed duration, wait for the last decisions, stop everything,
# and append one row to runs_summary.csv. No manual Ctrl+C needed.
#
# llama-server is NOT started here (loading Gemma takes minutes): start it beforehand.
#
# Examples:
#   scripts/run_experiment.sh --systems semif --duration 180 --rep 1
#   scripts/run_experiment.sh --systems gemma --duration 600 --rep 1
#   scripts/run_experiment.sh --systems semif,gemma --duration 600 --rep 1           # colocation
#   scripts/run_experiment.sh --systems semif --stress mem_stream --level 4 --rep 1
#   scripts/run_experiment.sh --systems gemma --stress cpu_matrix --level 4 --isolation pin_prio --rep 1
#
# Options:
#   --systems LIST      semif, gemma, qwen (comma-separated)         [semif]
#   --duration S        seconds of sensor stream                     [180]
#   --freq HZ           sensor rate                                  [2]
#   --seed N            simulator seed                               [42]
#   --rep N             repetition number (label)                    [1]
#   --stress TYPE       none, cpu_matrix, cpu_fft, mem_stream, mem_vm,
#                       cache_l1, sched_switch, io_hdd               [none]
#   --level N           stress-ng workers                            [0]
#   --isolation MODE    none, pin, prio, pin_prio                    [none]
#   --model-cores SET   cores for the models when pinning            [0-7]
#   --stress-cores SET  cores for the stressor when pinning          [8-11]
#   --rt-prio N         SCHED_FIFO priority for the models (prio)    [50]
#   --csv NAME          decision CSV file name in OUT_DIR            [runs.csv]
#   --grace S           wait for in-flight decisions after stream    [15]
#   --semif-mode MODE   direct or serial                             [direct]
#   --no-cache          disable prompt cache for generative nodes
#   --no-resources      do not run the jtop resource logger
#   --no-perf           do not collect perf counters
#
# Environment overrides: WS, VENV, ROS_SETUP, OUT_DIR.
set -euo pipefail

WS=${WS:-$HOME/RTSIASarnataroTafuri/rtsia_bench}           # colcon workspace (has install/)
VENV=${VENV:-$HOME/RTSIASarnataroTafuri/venv13}             # venv with torch + SemIf
ROS_SETUP=${ROS_SETUP:-/opt/ros/humble/setup.bash}
OUT_DIR=${OUT_DIR:-$HOME/RTSIASarnataroTafuri/risultati}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SYSTEMS=semif; DURATION=180; FREQ=2; SEED=42; REP=1
STRESS=none; LEVEL=0; ISOLATION=none
MODEL_CORES=0-7; STRESS_CORES=8-11; RT_PRIO=50
CSV=runs.csv; GRACE=15; SEMIF_MODE=direct
CACHE=true; RESOURCES=true; PERF_ON=true

usage() { sed -n '2,36p' "$0"; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --systems) SYSTEMS=$2; shift 2 ;;
    --duration) DURATION=$2; shift 2 ;;
    --freq) FREQ=$2; shift 2 ;;
    --seed) SEED=$2; shift 2 ;;
    --rep) REP=$2; shift 2 ;;
    --stress|--interference) STRESS=$2; shift 2 ;;
    --level) LEVEL=$2; shift 2 ;;
    --isolation) ISOLATION=$2; shift 2 ;;
    --model-cores) MODEL_CORES=$2; shift 2 ;;
    --stress-cores) STRESS_CORES=$2; shift 2 ;;
    --rt-prio) RT_PRIO=$2; shift 2 ;;
    --csv) CSV=$2; shift 2 ;;
    --grace) GRACE=$2; shift 2 ;;
    --semif-mode) SEMIF_MODE=$2; shift 2 ;;
    --no-cache) CACHE=false; shift ;;
    --no-resources) RESOURCES=false; shift ;;
    --no-perf) PERF_ON=false; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ---------------------------------------------------------------- validation
IFS=',' read -r -a SYS_LIST <<< "$SYSTEMS"
for s in "${SYS_LIST[@]}"; do
  [[ "$s" =~ ^(semif|gemma|qwen)$ ]] || { echo "Unknown system: $s"; exit 1; }
done
COLOCATION=$([[ ${#SYS_LIST[@]} -gt 1 ]] && echo yes || echo no)
[[ "$ISOLATION" =~ ^(none|pin|prio|pin_prio)$ ]] || { echo "Unknown isolation: $ISOLATION"; exit 1; }
PIN=false; PRIO=false
[[ $ISOLATION == pin || $ISOLATION == pin_prio ]] && PIN=true
[[ $ISOLATION == prio || $ISOLATION == pin_prio ]] && PRIO=true
NCPU=$(nproc)
ALL_CORES="0-$((NCPU - 1))"
max_core() { tr ',-' '\n\n' <<< "$1" | sort -n | tail -1; }   # highest core in a set like 0-3,6
if [[ $PIN == true ]]; then
  for set in "$MODEL_CORES" "$STRESS_CORES"; do
    [[ "$set" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || { echo "Invalid core set: $set"; exit 1; }
    [[ $(max_core "$set") -lt $NCPU ]] || { echo "Core set $set exceeds the $NCPU cores of this board"; exit 1; }
  done
fi

# stress-ng arguments for each stress type; LEVEL = number of workers.
stress_args() {
  local n=$1
  case $STRESS in
    cpu_matrix)   echo "--matrix $n" ;;
    cpu_fft)      echo "--cpu $n --cpu-method fft" ;;
    mem_stream)   echo "--stream $n" ;;
    mem_vm)       echo "--vm $n --vm-bytes 256M" ;;
    cache_l1)     echo "--l1cache $n" ;;
    sched_switch) echo "--switch $n" ;;
    io_hdd)       echo "--hdd $n --hdd-bytes 512M --temp-path /tmp" ;;
    *) return 1 ;;
  esac
}
if [[ $STRESS == none ]]; then
  LEVEL=0
else
  command -v stress-ng > /dev/null || { echo "stress-ng not installed"; exit 1; }
  stress_args 1 > /dev/null || { echo "Unknown stress type: $STRESS"; exit 1; }
  [[ $LEVEL -ge 1 ]] || { echo "--level must be >= 1 with --stress $STRESS"; exit 1; }
  # 1-second check: this stress-ng version must support the stressor.
  read -r -a CHECK <<< "$(stress_args 1)"
  stress-ng "${CHECK[@]}" --timeout 1s --quiet > /dev/null 2>&1 \
    || { echo "This stress-ng does not support '$STRESS' ($(stress_args 1))"; exit 1; }
fi
if [[ $PRIO == true ]]; then
  sudo -n true 2> /dev/null || { echo "Isolation '$ISOLATION' needs sudo for chrt: run 'sudo -v' first"; exit 1; }
fi

# ---------------------------------------------------------------- environment
set +u   # ROS setup scripts reference unset variables
source "$VENV/bin/activate"
source "$ROS_SETUP"
source "$WS/install/setup.bash"
set -u
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-42}
export ROS_LOCALHOST_ONLY=${ROS_LOCALHOST_ONLY:-1}

CONFIG_KEY="${SYSTEMS//,/+}_f${FREQ}_${STRESS}${LEVEL}_${ISOLATION}_r${REP}"
RUN_ID="$(date +%Y%m%d_%H%M%S)_${CONFIG_KEY}"
LOG_DIR="$OUT_DIR/logs/$RUN_ID"
mkdir -p "$LOG_DIR"
echo "== Run $RUN_ID"
echo "   logs: $LOG_DIR"

# llama-server instances needed by this run must answer; remember their PIDs.
LLAMA_PIDS=()
check_server() {
  curl -sf "http://127.0.0.1:$1/health" > /dev/null \
    || { echo "llama-server on port $1 is not answering: start it before this run."; exit 1; }
  local pid
  pid=$(pgrep -f "llama-server.*--port[ =]$1" | head -1 || true)
  if [[ -n $pid ]]; then LLAMA_PIDS+=("$pid"); else echo "   warning: PID of llama-server on port $1 not found (no isolation on it)"; fi
}
for s in "${SYS_LIST[@]}"; do
  [[ $s == gemma ]] && check_server 8080
  [[ $s == qwen ]] && check_server 8081
done

# ---------------------------------------------------------------- process handling
PIDS=()
cleanup() {
  # Restore llama-server scheduling, it outlives this run.
  for pid in "${LLAMA_PIDS[@]}"; do
    [[ $PIN == true ]] && taskset -a -cp "$ALL_CORES" "$pid" > /dev/null 2>&1 || true
    [[ $PRIO == true ]] && sudo -n chrt -a -o -p 0 "$pid" > /dev/null 2>&1 || true
  done
  # SIGTERM: background jobs ignore SIGINT in scripts; rclpy shuts down cleanly on SIGTERM.
  for pid in "${PIDS[@]}"; do kill -TERM "$pid" 2> /dev/null || true; done
  sleep 3
  for pid in "${PIDS[@]}"; do kill -KILL "$pid" 2> /dev/null || true; done
}
trap cleanup EXIT

start() {  # start NAME COMMAND... in the background, output to LOG_DIR/NAME.log
  local name=$1; shift
  "$@" > "$LOG_DIR/$name.log" 2>&1 &
  PIDS+=($!)
  echo "   started $name (pid $!)"
}

# With pinning, every ROS process runs on the model cores.
PIN_PREFIX=()
[[ $PIN == true ]] && PIN_PREFIX=(taskset -c "$MODEL_CORES")

# ---------------------------------------------------------------- metadata
STRESS_CMD="none"
[[ $STRESS != none ]] && STRESS_CMD="stress-ng $(stress_args "$LEVEL")"
{
  echo "run_id=$RUN_ID"; echo "config_key=$CONFIG_KEY"; echo "date=$(date -Is)"
  echo "systems=$SYSTEMS"; echo "colocation=$COLOCATION"
  echo "duration_s=$DURATION"; echo "freq_hz=$FREQ"; echo "seed=$SEED"; echo "repetition=$REP"
  echo "stress=$STRESS"; echo "level_workers=$LEVEL"; echo "stress_cmd=$STRESS_CMD"
  echo "isolation=$ISOLATION"; echo "model_cores=$([[ $PIN == true ]] && echo "$MODEL_CORES" || echo all)"
  echo "stress_cores=$([[ $PIN == true ]] && echo "$STRESS_CORES" || echo all)"
  echo "rt_prio=$([[ $PRIO == true ]] && echo "$RT_PRIO" || echo none)"
  echo "semif_mode=$SEMIF_MODE"; echo "prompt_cache=$CACHE"; echo "ncpu=$NCPU"
  echo "power_mode=$(nvpmodel -q 2> /dev/null | tr '\n' ' ' || echo unknown)"
} > "$LOG_DIR/run_info.txt"

# ---------------------------------------------------------------- 1. loggers
if [[ $RESOURCES == true ]]; then
  # System Python: jtop is installed there, not in the venv.
  start resources /usr/bin/python3 "$SCRIPT_DIR/resource_logger.py" \
    --out "$OUT_DIR/resources_$RUN_ID.csv" --interval 0.1
fi
start logger "${PIN_PREFIX[@]}" python -m rtsia_bench.logger --ros-args \
  -p file:="$OUT_DIR/$CSV" -p run_id:="$RUN_ID" -p freq_hz:="$FREQ" \
  -p interference:="$STRESS" -p interference_level:="$LEVEL" \
  -p isolation:="$ISOLATION" -p colocation:="$COLOCATION" -p repetition:="$REP"

# ---------------------------------------------------------------- 2. decision nodes
NODE_PIDS=()
SEMIF_PID=""
for s in "${SYS_LIST[@]}"; do
  case $s in
    semif) start semif "${PIN_PREFIX[@]}" python -m rtsia_bench.semif_node --ros-args -p mode:="$SEMIF_MODE"
           SEMIF_PID=${PIDS[-1]} ;;
    gemma) start gemma "${PIN_PREFIX[@]}" python -m rtsia_bench.llm_gen_node --ros-args \
             -r __node:=llm_gen_gemma -p cache_prompt:="$CACHE" ;;
    qwen)  start qwen "${PIN_PREFIX[@]}" python -m rtsia_bench.llm_gen_node --ros-args \
             -r __node:=llm_gen_qwen -p url:=http://127.0.0.1:8081/v1/chat/completions \
             -p system:=gen-qwen4b -p topic:=decision/qwen -p cache_prompt:="$CACHE" ;;
  esac
  NODE_PIDS+=("${PIDS[-1]}")
done

if [[ -n $SEMIF_PID ]]; then
  echo "   waiting for SemIf to load..."
  for _ in $(seq 1 600); do
    grep -q "SemIf ready" "$LOG_DIR/semif.log" 2> /dev/null && break
    kill -0 "$SEMIF_PID" 2> /dev/null || { echo "SemIf exited during loading, see $LOG_DIR/semif.log"; exit 1; }
    sleep 1
  done
  grep -q "SemIf ready" "$LOG_DIR/semif.log" || { echo "SemIf not ready after 10 min"; exit 1; }
fi

# ---------------------------------------------------------------- 3. isolation
if [[ $PIN == true ]]; then
  for pid in "${LLAMA_PIDS[@]}"; do taskset -a -cp "$MODEL_CORES" "$pid" > /dev/null; done
  echo "   pinned models to cores $MODEL_CORES, stressor to $STRESS_CORES"
fi
if [[ $PRIO == true ]]; then
  for pid in "${NODE_PIDS[@]}" "${LLAMA_PIDS[@]}"; do sudo -n chrt -a -f -p "$RT_PRIO" "$pid"; done
  echo "   SCHED_FIFO priority $RT_PRIO on decision nodes and llama-server"
fi

# ---------------------------------------------------------------- 4. stressor
if [[ $STRESS != none ]]; then
  read -r -a SARGS <<< "$(stress_args "$LEVEL")"
  SPREFIX=()
  [[ $PIN == true ]] && SPREFIX=(taskset -c "$STRESS_CORES")
  start stress "${SPREFIX[@]}" stress-ng "${SARGS[@]}" \
    --timeout "$((DURATION + GRACE + 60))s" --metrics-brief
  sleep 1
  kill -0 "${PIDS[-1]}" 2> /dev/null || { echo "Stressor failed to start, see $LOG_DIR/stress.log"; exit 1; }
fi
sleep 3   # node discovery before the stream starts

# ---------------------------------------------------------------- 5. perf counters (optional)
PERF=()
PERF_SRC=none
if [[ $PERF_ON == true ]] && command -v perf > /dev/null; then
  if perf stat -a -x, -e cache-misses -- true > /dev/null 2>&1; then PERF=(perf); PERF_SRC=perf
  elif sudo -n perf stat -a -x, -e cache-misses -- true > /dev/null 2>&1; then PERF=(sudo -n perf); PERF_SRC=sudo_perf
  fi
fi
if [[ ${#PERF[@]} -gt 0 ]]; then
  "${PERF[@]}" stat -a -x, -e cache-misses,branch-misses -o "$LOG_DIR/perf.csv" \
    -- sleep "$DURATION" > /dev/null 2>&1 &
  PIDS+=($!)
elif [[ $PERF_ON == true ]]; then
  echo "   perf not available: cache/branch misses not collected"
fi

# ---------------------------------------------------------------- 6. sensor stream (foreground)
ctxt() { awk '/^ctxt/ {print $2}' /proc/stat; }
CTXT_START=$(ctxt); T_START=$(date +%s.%N)
echo "   streaming for ${DURATION}s at ${FREQ} Hz (stress: $STRESS x$LEVEL, isolation: $ISOLATION)..."
SENSOR_RC=0
"${PIN_PREFIX[@]}" python -m rtsia_bench.sensor_sim --ros-args \
  -p rate_hz:="$FREQ" -p seed:="$SEED" -p duration_s:="$DURATION" \
  > "$LOG_DIR/sensor_sim.log" 2>&1 || SENSOR_RC=$?
if [[ $SENSOR_RC -ne 0 ]]; then
  echo "== FAILED: sensor_sim exited with an error, see $LOG_DIR/sensor_sim.log"
  tail -3 "$LOG_DIR/sensor_sim.log"
  exit 1
fi
CTXT_END=$(ctxt); T_END=$(date +%s.%N)

echo "   stream finished, waiting ${GRACE}s for in-flight decisions..."
sleep "$GRACE"

# ---------------------------------------------------------------- 7. run summary
N_DEC=$(grep -c "$RUN_ID" "$OUT_DIR/$CSV" 2> /dev/null || true); N_DEC=${N_DEC:-0}
CTXT_RATE=$(awk -v a="$CTXT_START" -v b="$CTXT_END" -v t0="$T_START" -v t1="$T_END" \
  'BEGIN {printf "%.0f", (b - a) / (t1 - t0)}')
perf_value() {  # value of one event from perf's CSV output, NA if missing
  [[ -s "$LOG_DIR/perf.csv" ]] || { echo NA; return; }
  awk -F, -v e="$1" '$3 ~ e {v = $1} END {print (v == "" || v ~ /not/) ? "NA" : v}' "$LOG_DIR/perf.csv"
}
SUMMARY="$OUT_DIR/runs_summary.csv"
[[ -s $SUMMARY ]] || echo "run_id,config_key,date,systems,colocation,freq_hz,duration_s,stress,level_workers,isolation,repetition,n_decisions,ctxt_per_s,cache_misses,branch_misses,perf_source" > "$SUMMARY"
echo "$RUN_ID,$CONFIG_KEY,$(date -Is),${SYSTEMS//,/+},$COLOCATION,$FREQ,$DURATION,$STRESS,$LEVEL,$ISOLATION,$REP,$N_DEC,$CTXT_RATE,$(perf_value cache-misses),$(perf_value branch-misses),$PERF_SRC" >> "$SUMMARY"

if [[ $N_DEC -eq 0 ]]; then
  echo "== FAILED: 0 decisions recorded. Check the logs in $LOG_DIR (sensor_sim.log first)."
  exit 1
fi
echo "== Done: $N_DEC decisions, $CTXT_RATE context switches/s -> $OUT_DIR/$CSV"
