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
#   --stress TYPE       stress-ng: cpu_matrix, cpu_fft, mem_stream, mem_vm,
#                       cache_l1, sched_switch, io_hdd
#                       rt-app (periodic threads, see below): rtapp_other,
#                       rtapp_fifo[P], rtapp_heavy[P], rtapp_burst[P]   [none]
#   --level N           stress-ng workers / rt-app threads           [0]
#   --isolation MODE    none, pin, prio, pin_prio                    [none]
#                       prio[P] / pin_prio[P]: SCHED_FIFO priority P (1-98) for the
#                       models, e.g. prio80, pin_prio80 (no number = --rt-prio)
#                       MODE@SYSTEM applies it to one system only in colocation,
#                       e.g. pin@semif, prio@gemma, pin_prio80@semif
#   --model-cores SET   cores for the models when pinning            [0-7]
#   --stress-cores SET  cores for the stressor when pinning          [8-11]
#   --other-cores SET   cores for the NON-isolated system (MODE@SYSTEM) [8-11]
#   --rt-prio N         SCHED_FIFO priority for the models (prio)    [50]
#   --rtapp-prio N      default SCHED_FIFO priority of rt-app threads [60]
#   --csv NAME          decision CSV file name in OUT_DIR            [runs.csv]
#   --grace S           wait for in-flight decisions after stream    [15]
#   --semif-mode MODE   direct or serial                             [direct]
#   --no-cache          disable prompt cache for generative nodes
#   --no-resources      do not run the jtop resource logger
#   --no-perf           do not collect perf counters
#
# rt-app profiles (each thread: busy for RUN, then sleeps until the next PERIOD):
#   rtapp_other      SCHED_OTHER (normal priority)   run 5 ms every 10 ms  (50% per thread)
#   rtapp_fifo[P]    SCHED_FIFO priority P           run 5 ms every 10 ms  (50%)
#   rtapp_heavy[P]   SCHED_FIFO priority P           run 9 ms every 10 ms  (90%)
#   rtapp_burst[P]   SCHED_FIFO priority P           run 20 ms every 100 ms (20%, long bursts)
#   P omitted = --rtapp-prio (60). With pin/pin_prio the threads run on --stress-cores.
#   rt-app is calibrated once (ns per loop) and the value is cached in
#   OUT_DIR/rtapp_calibration.txt, so every run gets exactly the same workload.
#
# Environment overrides: WS, VENV, ROS_SETUP, OUT_DIR, RTAPP (rt-app binary).
set -euo pipefail

WS=${WS:-$HOME/RTSIASarnataroTafuri/rtsia_bench}           # colcon workspace (has install/)
VENV=${VENV:-$HOME/RTSIASarnataroTafuri/venv13}             # venv with torch + SemIf
ROS_SETUP=${ROS_SETUP:-/opt/ros/humble/setup.bash}
OUT_DIR=${OUT_DIR:-$HOME/RTSIASarnataroTafuri/risultati}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SYSTEMS=semif; DURATION=180; FREQ=2; SEED=42; REP=1
STRESS=none; LEVEL=0; ISOLATION=none
MODEL_CORES=0-7; STRESS_CORES=8-11; OTHER_CORES=8-11; RT_PRIO=50; RTAPP_PRIO=60
RTAPP=${RTAPP:-rt-app}
CSV=runs.csv; GRACE=15; SEMIF_MODE=direct
CACHE=true; RESOURCES=true; PERF_ON=true

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 1; }
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
    --other-cores) OTHER_CORES=$2; shift 2 ;;
    --rt-prio) RT_PRIO=$2; shift 2 ;;
    --rtapp-prio) RTAPP_PRIO=$2; shift 2 ;;
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
ISO_TARGET=all
if [[ "$ISOLATION" == *@* ]]; then
  ISO_TARGET=${ISOLATION#*@}
  ISOLATION=${ISOLATION%@*}
  [[ " ${SYS_LIST[*]} " == *" $ISO_TARGET "* ]] || { echo "Isolation target '$ISO_TARGET' is not among the systems of this run ($SYSTEMS)"; exit 1; }
fi
# Label used in CSV, run_id and summary: pin, prio, pin_prio80, or e.g. pin_semif / prio80_gemma.
ISO_LABEL=$ISOLATION
if [[ "$ISOLATION" =~ ^(prio|pin_prio)([0-9]+)$ ]]; then   # prio80 -> prio with priority 80
  ISOLATION=${BASH_REMATCH[1]}; RT_PRIO=${BASH_REMATCH[2]}
fi
[[ "$ISOLATION" =~ ^(none|pin|prio|pin_prio)$ ]] || { echo "Unknown isolation: $ISO_LABEL"; exit 1; }
[[ $ISOLATION == none && $ISO_TARGET != all ]] && { echo "none@SYSTEM makes no sense: use none"; exit 1; }
[[ "$RT_PRIO" =~ ^[0-9]+$ && $RT_PRIO -ge 1 && $RT_PRIO -le 98 ]] \
  || { echo "Model priority must be 1-98 (99 belongs to kernel threads): $RT_PRIO"; exit 1; }
[[ $ISO_TARGET != all ]] && ISO_LABEL="${ISOLATION}_${ISO_TARGET}"
PIN=false; PRIO=false
[[ $ISOLATION == pin || $ISOLATION == pin_prio ]] && PIN=true
[[ $ISOLATION == prio || $ISOLATION == pin_prio ]] && PRIO=true
is_target() { [[ $ISO_TARGET == all || $ISO_TARGET == "$1" ]]; }
NCPU=$(nproc)
ALL_CORES="0-$((NCPU - 1))"
max_core() { tr ',-' '\n\n' <<< "$1" | sort -n | tail -1; }   # highest core in a set like 0-3,6
if [[ $PIN == true ]]; then
  for set in "$MODEL_CORES" "$STRESS_CORES" "$OTHER_CORES"; do
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

# rt-app stress types: rtapp_<profile>[priority]
RTAPP_ON=false; RTAPP_POLICY=""; RTAPP_RUN=0; RTAPP_PERIOD=0; RTAPP_JSON=""
if [[ "$STRESS" =~ ^rtapp_(other|fifo|heavy|burst)([0-9]*)$ ]]; then
  RTAPP_ON=true
  RTAPP_PROFILE=${BASH_REMATCH[1]}
  [[ -n ${BASH_REMATCH[2]} ]] && RTAPP_PRIO=${BASH_REMATCH[2]}
  case $RTAPP_PROFILE in
    other) RTAPP_POLICY=SCHED_OTHER; RTAPP_RUN=5000;  RTAPP_PERIOD=10000
           [[ -n ${BASH_REMATCH[2]} ]] && { echo "rtapp_other has no priority (normal process): use rtapp_other"; exit 1; } ;;
    fifo)  RTAPP_POLICY=SCHED_FIFO;  RTAPP_RUN=5000;  RTAPP_PERIOD=10000 ;;
    heavy) RTAPP_POLICY=SCHED_FIFO;  RTAPP_RUN=9000;  RTAPP_PERIOD=10000 ;;
    burst) RTAPP_POLICY=SCHED_FIFO;  RTAPP_RUN=20000; RTAPP_PERIOD=100000 ;;
  esac
  [[ "$RTAPP_PRIO" =~ ^[0-9]+$ && $RTAPP_PRIO -ge 1 && $RTAPP_PRIO -le 98 ]] \
    || { echo "rt-app priority must be 1-98: $RTAPP_PRIO"; exit 1; }
fi
stress_cmd_text() {
  if [[ $RTAPP_ON == true ]]; then
    echo "rt-app $LEVEL x $RTAPP_POLICY$([[ $RTAPP_POLICY == SCHED_FIFO ]] && echo " prio $RTAPP_PRIO") run ${RTAPP_RUN}us period ${RTAPP_PERIOD}us"
  else
    echo "stress-ng $(stress_args "$LEVEL")"
  fi
}

if [[ $STRESS == none ]]; then
  LEVEL=0
elif [[ $RTAPP_ON == true ]]; then
  command -v "$RTAPP" > /dev/null || { echo "rt-app not installed (sudo apt install rt-app, or set RTAPP=/path/to/rt-app)"; exit 1; }
  [[ $LEVEL -ge 1 ]] || { echo "--level must be >= 1 with --stress $STRESS"; exit 1; }
  if [[ $RTAPP_POLICY == SCHED_FIFO ]]; then
    # Safety: real-time threads on every core can freeze the board.
    [[ $LEVEL -lt $NCPU ]] || { echo "rt-app SCHED_FIFO: at most $((NCPU - 1)) threads (keep one core free)"; exit 1; }
    sudo -n true 2> /dev/null || { echo "Stress '$STRESS' (SCHED_FIFO) needs sudo: run 'sudo -v' first"; exit 1; }
  fi
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
  sudo -n true 2> /dev/null || { echo "Isolation '$ISO_LABEL' needs sudo for chrt: run 'sudo -v' first"; exit 1; }
fi

# rt-app calibration (ns per loop), once per OUT_DIR, on a stress core while the board is quiet.
RTAPP_PLOAD=""
cores_json() {  # "8-11" -> "8, 9, 10, 11"
  local out=() part a b c
  IFS=',' read -r -a parts <<< "$1"
  for part in "${parts[@]}"; do
    a=${part%-*}; b=${part#*-}
    for ((c = a; c <= b; c++)); do out+=("$c"); done
  done
  local IFS=','; echo "${out[*]}" | sed 's/,/, /g'
}
if [[ $RTAPP_ON == true ]]; then
  CAL_FILE="$OUT_DIR/rtapp_calibration.txt"
  if [[ -s "$CAL_FILE" ]]; then
    RTAPP_PLOAD=$(tr -dc '0-9' < "$CAL_FILE")
  else
    mkdir -p "$OUT_DIR"
    CAL_CPU=$(cores_json "$STRESS_CORES" | cut -d, -f1)
    CAL_JSON=$(mktemp /tmp/rtsia_rtcal_XXXXXX.json)
    cat > "$CAL_JSON" <<JSON
{ "global": { "duration": 1, "calibration": "CPU$CAL_CPU", "lock_pages": false,
              "logdir": "/tmp", "log_size": "disable", "ftrace": "none", "gnuplot": false },
  "tasks": { "cal": { "loop": -1, "run": 1000, "timer": { "ref": "unique", "period": 10000 } } } }
JSON
    echo "== rt-app calibration on CPU$CAL_CPU (once, cached in $CAL_FILE)..."
    RTAPP_PLOAD=$("$RTAPP" "$CAL_JSON" 2>&1 | sed -n 's/.*pLoad = \([0-9]*\)ns.*/\1/p' | head -1)
    rm -f "$CAL_JSON"
    [[ -n $RTAPP_PLOAD ]] || { echo "rt-app calibration failed: run '$RTAPP $CAL_JSON' by hand to see the error"; exit 1; }
    echo "$RTAPP_PLOAD" > "$CAL_FILE"
  fi
  [[ "$RTAPP_PLOAD" =~ ^[0-9]+$ && $RTAPP_PLOAD -gt 0 ]] || { echo "Bad rt-app calibration in $CAL_FILE: delete it to recalibrate"; exit 1; }
  echo "   rt-app: $RTAPP_PLOAD ns per loop"
fi

# ---------------------------------------------------------------- environment
set +u   # ROS setup scripts reference unset variables
source "$VENV/bin/activate"
source "$ROS_SETUP"
source "$WS/install/setup.bash"
set -u
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-42}
export ROS_LOCALHOST_ONLY=${ROS_LOCALHOST_ONLY:-1}

LVL_SEP=""; [[ $STRESS =~ [0-9]$ ]] && LVL_SEP=x   # rtapp_fifo60 + 4 workers -> rtapp_fifo60x4
CONFIG_KEY="${SYSTEMS//,/+}_f${FREQ}_${STRESS}${LVL_SEP}${LEVEL}_${ISO_LABEL}_r${REP}"
RUN_ID="$(date +%Y%m%d_%H%M%S)_${CONFIG_KEY}"
LOG_DIR="$OUT_DIR/logs/$RUN_ID"
mkdir -p "$LOG_DIR"
echo "== Run $RUN_ID"
echo "   logs: $LOG_DIR"

# llama-server instances needed by this run must answer; remember their PIDs.
LLAMA_PIDS=(); LLAMA_SYS=()
check_server() {  # check_server PORT SYSTEM
  curl -sf "http://127.0.0.1:$1/health" > /dev/null \
    || { echo "llama-server on port $1 is not answering: start it before this run."; exit 1; }
  local pid
  pid=$(pgrep -f "llama-server.*--port[ =]$1" | head -1 || true)
  if [[ -n $pid ]]; then LLAMA_PIDS+=("$pid"); LLAMA_SYS+=("$2"); else echo "   warning: PID of llama-server on port $1 not found (no isolation on it)"; fi
}
for s in "${SYS_LIST[@]}"; do
  [[ $s == gemma ]] && check_server 8080 gemma
  [[ $s == qwen ]] && check_server 8081 qwen
done

# ---------------------------------------------------------------- process handling
PIDS=()
cleanup() {
  # Restore llama-server scheduling, it outlives this run.
  for pid in "${LLAMA_PIDS[@]}"; do
    [[ $PIN == true ]] && taskset -a -cp "$ALL_CORES" "$pid" > /dev/null 2>&1 || true
    [[ $PRIO == true ]] && sudo -n chrt -a -o -p 0 "$pid" > /dev/null 2>&1 || true
  done
  # rt-app may run under sudo: stop it by name (sudo does not forward signals from this script).
  if [[ $RTAPP_ON == true ]]; then
    if [[ $RTAPP_POLICY == SCHED_FIFO ]]; then sudo -n pkill -TERM -x rt-app 2> /dev/null || true
    else pkill -TERM -x rt-app 2> /dev/null || true; fi
  fi
  # SIGTERM: background jobs ignore SIGINT in scripts; rclpy shuts down cleanly on SIGTERM.
  for pid in "${PIDS[@]}"; do kill -TERM "$pid" 2> /dev/null || true; done
  sleep 3
  for pid in "${PIDS[@]}"; do kill -KILL "$pid" 2> /dev/null || true; done
  if [[ $RTAPP_ON == true ]]; then
    sudo -n pkill -KILL -x rt-app 2> /dev/null || pkill -KILL -x rt-app 2> /dev/null || true
  fi
  if [[ -n $RTAPP_JSON ]]; then rm -f "$RTAPP_JSON"; fi
  return 0   # never change the exit code of the run (set -e + EXIT trap)
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
cores_for() {  # cores for a model system: protected cores if isolated, otherwise the "other" cores
  if is_target "$1"; then echo "$MODEL_CORES"; else echo "$OTHER_CORES"; fi
}
SYS_PREFIX_semif=(); SYS_PREFIX_gemma=(); SYS_PREFIX_qwen=()
if [[ $PIN == true ]]; then
  SYS_PREFIX_semif=(taskset -c "$(cores_for semif)")
  SYS_PREFIX_gemma=(taskset -c "$(cores_for gemma)")
  SYS_PREFIX_qwen=(taskset -c "$(cores_for qwen)")
fi

# ---------------------------------------------------------------- metadata
STRESS_CMD="none"
[[ $STRESS != none ]] && STRESS_CMD="$(stress_cmd_text)"
{
  echo "run_id=$RUN_ID"; echo "config_key=$CONFIG_KEY"; echo "date=$(date -Is)"
  echo "systems=$SYSTEMS"; echo "colocation=$COLOCATION"
  echo "duration_s=$DURATION"; echo "freq_hz=$FREQ"; echo "seed=$SEED"; echo "repetition=$REP"
  echo "stress=$STRESS"; echo "level_workers=$LEVEL"; echo "stress_cmd=$STRESS_CMD"
  echo "isolation=$ISO_LABEL"; echo "isolation_target=$ISO_TARGET"
  echo "model_cores=$([[ $PIN == true ]] && echo "$MODEL_CORES" || echo all)"
  echo "other_cores=$([[ $PIN == true && $ISO_TARGET != all ]] && echo "$OTHER_CORES" || echo none)"
  echo "stress_cores=$([[ $PIN == true ]] && echo "$STRESS_CORES" || echo all)"
  echo "rt_prio=$([[ $PRIO == true ]] && echo "$RT_PRIO" || echo none)"
  [[ $RTAPP_ON == true ]] && { echo "rtapp_policy=$RTAPP_POLICY"; echo "rtapp_prio=$([[ $RTAPP_POLICY == SCHED_FIFO ]] && echo "$RTAPP_PRIO" || echo none)"; echo "rtapp_run_us=$RTAPP_RUN"; echo "rtapp_period_us=$RTAPP_PERIOD"; echo "rtapp_ns_per_loop=$RTAPP_PLOAD"; }
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
  -p isolation:="$ISO_LABEL" -p colocation:="$COLOCATION" -p repetition:="$REP"

# ---------------------------------------------------------------- 2. decision nodes
NODE_PIDS=(); NODE_SYS=()
SEMIF_PID=""
for s in "${SYS_LIST[@]}"; do
  case $s in
    semif) start semif "${SYS_PREFIX_semif[@]}" python -m rtsia_bench.semif_node --ros-args -p mode:="$SEMIF_MODE"
           SEMIF_PID=${PIDS[-1]} ;;
    gemma) start gemma "${SYS_PREFIX_gemma[@]}" python -m rtsia_bench.llm_gen_node --ros-args \
             -r __node:=llm_gen_gemma -p cache_prompt:="$CACHE" ;;
    qwen)  start qwen "${SYS_PREFIX_qwen[@]}" python -m rtsia_bench.llm_gen_node --ros-args \
             -r __node:=llm_gen_qwen -p url:=http://127.0.0.1:8081/v1/chat/completions \
             -p system:=gen-qwen4b -p topic:=decision/qwen -p cache_prompt:="$CACHE" ;;
  esac
  NODE_PIDS+=("${PIDS[-1]}"); NODE_SYS+=("$s")
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
  for i in "${!LLAMA_PIDS[@]}"; do taskset -a -cp "$(cores_for "${LLAMA_SYS[$i]}")" "${LLAMA_PIDS[$i]}" > /dev/null; done
  if [[ $ISO_TARGET == all ]]; then echo "   pinned models to cores $MODEL_CORES, stressor to $STRESS_CORES"; else echo "   pinned $ISO_TARGET to cores $MODEL_CORES, other model(s) to $OTHER_CORES, stressor to $STRESS_CORES"; fi
fi
if [[ $PRIO == true ]]; then
  for i in "${!NODE_PIDS[@]}"; do is_target "${NODE_SYS[$i]}" && sudo -n chrt -a -f -p "$RT_PRIO" "${NODE_PIDS[$i]}"; done
  for i in "${!LLAMA_PIDS[@]}"; do is_target "${LLAMA_SYS[$i]}" && sudo -n chrt -a -f -p "$RT_PRIO" "${LLAMA_PIDS[$i]}"; done
  echo "   SCHED_FIFO priority $RT_PRIO on: $([[ $ISO_TARGET == all ]] && echo "all decision nodes and llama-server" || echo "$ISO_TARGET only")"
fi

# ---------------------------------------------------------------- 4. stressor
if [[ $RTAPP_ON == true ]]; then
  if [[ $PIN == true ]]; then RT_CPUS="\"cpus\": [$(cores_json "$STRESS_CORES")], "; else RT_CPUS=""; fi
  RT_PRIO_JSON=""; [[ $RTAPP_POLICY == SCHED_FIFO ]] && RT_PRIO_JSON="\"priority\": $RTAPP_PRIO, "
  RTAPP_JSON=$(mktemp /tmp/rtsia_rtapp_XXXXXX.json)
  cat > "$RTAPP_JSON" <<JSON
{
  "global": {
    "duration": $((DURATION + GRACE + 60)),
    "calibration": $RTAPP_PLOAD,
    "default_policy": "SCHED_OTHER",
    "lock_pages": false,
    "logdir": "$LOG_DIR",
    "log_basename": "rtapp",
    "log_size": "disable",
    "ftrace": "none",
    "gnuplot": false
  },
  "tasks": {
    "rtapp_load": {
      "instance": $LEVEL, "loop": -1,
      "policy": "$RTAPP_POLICY", $RT_PRIO_JSON$RT_CPUS
      "run": $RTAPP_RUN,
      "timer": { "ref": "unique", "period": $RTAPP_PERIOD }
    }
  }
}
JSON
  cp "$RTAPP_JSON" "$LOG_DIR/rtapp.json"
  RT_SUDO=(); [[ $RTAPP_POLICY == SCHED_FIFO ]] && RT_SUDO=(sudo -n)
  start stress "${RT_SUDO[@]}" "$(command -v "$RTAPP")" "$RTAPP_JSON"
  sleep 1
  kill -0 "${PIDS[-1]}" 2> /dev/null || { echo "rt-app failed to start, see $LOG_DIR/stress.log"; tail -5 "$LOG_DIR/stress.log"; exit 1; }
  echo "   rt-app: $(stress_cmd_text)$([[ $PIN == true ]] && echo " on cores $STRESS_CORES")"
elif [[ $STRESS != none ]]; then
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
echo "   streaming for ${DURATION}s at ${FREQ} Hz (stress: $STRESS x$LEVEL, isolation: $ISO_LABEL)..."
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
echo "$RUN_ID,$CONFIG_KEY,$(date -Is),${SYSTEMS//,/+},$COLOCATION,$FREQ,$DURATION,$STRESS,$LEVEL,$ISO_LABEL,$REP,$N_DEC,$CTXT_RATE,$(perf_value cache-misses),$(perf_value branch-misses),$PERF_SRC" >> "$SUMMARY"

if [[ $N_DEC -eq 0 ]]; then
  echo "== FAILED: 0 decisions recorded. Check the logs in $LOG_DIR (sensor_sim.log first)."
  exit 1
fi
# Every system of the run must have produced decisions (e.g. a crashed Gemma node
# in a colocation run would otherwise go unnoticed behind SemIf's decisions).
declare -A SYS_NAME=([semif]=semif-qwen4b [gemma]=gen-gemma31b [qwen]=gen-qwen4b)
for s in "${SYS_LIST[@]}"; do
  n=$(grep "$RUN_ID" "$OUT_DIR/$CSV" | grep -c "^${SYS_NAME[$s]}," || true)
  if [[ ${n:-0} -eq 0 ]]; then
    echo "== FAILED: no decisions from $s. See $LOG_DIR/$s.log:"
    tail -5 "$LOG_DIR/$s.log"
    exit 1
  fi
  echo "   $s: $n decisions"
done
echo "== Done: $N_DEC decisions, $CTXT_RATE context switches/s -> $OUT_DIR/$CSV"
