# rtsia_bench

ROS 2 package that compares **SemIf** (one forward pass, option probabilities, no decoding)
with **generative LLMs** served by llama.cpp (Gemma 4 31B Q8, plus a Qwen3.5-4B control arm)
on a Jetson AGX Orin. Every system receives the same sensor stream; every decision is logged
as one CSV row ready for JMP.

```
sensor_sim ──/sensors──┬──> semif_node ─────────────> /decision/semif ──┐
                        ├──> llm_gen_node (8080) ────> /decision/gemma ──┼──> logger ──> runs.csv
                        └──> llm_gen_node (8081) ────> /decision/qwen ───┘
```

## Files

| File | Purpose |
| --- | --- |
| `rtsia_bench/common.py` | QoS profile, question and options shared by all systems |
| `rtsia_bench/sensor_sim.py` | Seeded sensor stream + rule-based expected action (ground truth) |
| `rtsia_bench/latest_queue.py` | Single-slot queue: keeps the newest sample, counts dropped ones |
| `rtsia_bench/semif_adapter.py` | Wrapper around the SemIf PyTorch backend (load once, warm up, score one row) |
| `rtsia_bench/semif_node.py` | SemIf decision node |
| `rtsia_bench/llm_gen_node.py` | Generative node (llama-server, JSON schema enum output) |
| `rtsia_bench/logger.py` | Writes one CSV row per decision, with experimental factors |
| `scripts/run_experiment.sh` | One run: nodes, stressor, isolation, automatic stop, run summary |
| `scripts/run_campaign.sh` | A block of runs from a plan file (repetitions, shuffle, resume) |
| `plans/*.plan` | Experiment blocks B1-B5 |
| `scripts/resource_logger.py` | jtop logger (GPU/CPU/RAM/power/temps) on the same monotonic clock |

## Install

```bash
# virtualenv with Jetson PyTorch + SemIf (see SemIf install notes)
source ~/.venvs/semif/bin/activate
source /opt/ros/$ROS_DISTRO/setup.bash

mkdir -p ~/rtsia_ws/src
cp -r rtsia_bench ~/rtsia_ws/src/
cd ~/rtsia_ws && colcon build --symlink-install
source install/setup.bash
```

**Important:** with `--symlink-install`, colcon generates the `ros2 run` executables with the
system Python (`#!/usr/bin/python3`), which cannot see the virtualenv. `semif_node` needs torch
and SemIf from the venv, so launch the nodes as modules with the venv active:

```bash
python -m rtsia_bench.semif_node          # instead of: ros2 run rtsia_bench semif_node
```

`scripts/run_experiment.sh` already does this for every node.

Recommended in `~/.bashrc` on a shared board:

```bash
export ROS_DOMAIN_ID=42              # pick your own
export ROS_LOCALHOST_ONLY=1          # Jazzy: export ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST
```

## Decision task

The decision rules are a fixed part of the task and are written in the option descriptions
(`rtsia_bench/common.py`), so every model decides with the same information:

| Action | Rule |
| --- | --- |
| `stop` | obstacle closer than 0.5 m, or motor temperature above 90 degrees C |
| `slow_down` | no stop condition, and obstacle closer than 1.5 m or motor temperature above 75 degrees C |
| `proceed` | obstacle at least 1.5 m away and motor temperature at most 75 degrees C |

`sensor_sim.expected_action()` implements exactly the same rules (checked on the boundary values
and on 100,000 random states). `speed_m_s` is in the state but not in the rules. With the default
seed the classes are unbalanced (about 58% proceed, 34% slow_down, 8% stop), so report accuracy
per class, not only overall.

For the generative models the prompt puts question and options first and the sensor state last,
so llama-server's prompt cache can reuse the fixed part (`cache_prompt:=true`). SemIf's own prompt
format puts the evidence first and, in `direct` mode, uses no cache: state which cache setting is
used when comparing the systems.

## SemIf adapter

`rtsia_bench/semif_adapter.py` wraps the SemIf **PyTorch** backend (`semif_phase1`), the same
code path as `semif-score --backend torch`. SemIf's llama.cpp backend is not used because it
hard-codes `n_gpu_layers = 0` (CPU only).

Requirements inside the virtualenv:

```bash
python -c "import torch; print(torch.cuda.is_available())"          # must print True
python -c "import transformers; print(hasattr(transformers, 'Qwen3_5ForCausalLM'))"  # must print True
python -c "import semif_phase1"                                       # SemIf installed with pip install -e . --no-deps
```

The model is loaded once in BF16 on the Orin GPU, with a pinned revision, and warmed up
with a few dummy decisions before the node starts listening. Two modes:

- `direct` (default): one forward pass per decision. Right for a sensor stream, where the
  state changes at every sample.
- `serial`: SemIf's state-prefix cache. Useful only when consecutive decisions share the
  exact same state; with a changing state it adds a cache copy to every call.

SemIf's forward pass is logged as `prefill_ms` (with `decode_ms = 0`), so it can be compared
directly with the prefill phase of the generative models.

## Automatic runs (recommended)

Two scripts automate the experiments. Run them from the package folder (on the RTSIA board
the package is the workspace root: `~/RTSIASarnataroTafuri/rtsia_bench`, no `src/`).

### One run: `scripts/run_experiment.sh`

Starts the resource logger, the decision logger and the decision nodes, waits for SemIf to
load, applies isolation, starts the stressor, streams sensor data for a fixed duration, waits
for the last decisions, stops everything and appends one row to `runs_summary.csv`.
llama-server is not started by the script (loading Gemma takes minutes): start it beforehand.

```bash
scripts/run_experiment.sh --systems semif --duration 180 --rep 1 --csv campagna.csv
scripts/run_experiment.sh --systems semif,gemma --duration 600 --rep 1 --csv campagna.csv
scripts/run_experiment.sh --systems semif --stress mem_stream --level 4 --rep 1 --csv campagna.csv
scripts/run_experiment.sh --systems gemma --stress cpu_matrix --level 4 --isolation pin_prio --rep 1 --csv campagna.csv
```

Run `scripts/run_experiment.sh --help` for all options.

**Stress types** (`--stress`, with `--level` = number of stress-ng workers):

| Type | stress-ng | Hardware target |
| --- | --- | --- |
| `cpu_matrix` | `--matrix N` | CPU compute, caches |
| `cpu_fft` | `--cpu N --cpu-method fft` | CPU floating point |
| `mem_stream` | `--stream N` | Memory bandwidth (shared by CPU and GPU) |
| `mem_vm` | `--vm N --vm-bytes 256M` | Virtual memory, page faults |
| `cache_l1` | `--l1cache N` | L1 cache thrashing |
| `sched_switch` | `--switch N` | Scheduler, context switches |
| `io_hdd` | `--hdd N --hdd-bytes 512M` | Disk I/O |

Before each run the script tests the stressor for 1 s and stops with a clear message if the
installed stress-ng does not support it.

**Isolation** (`--isolation`):

| Mode | What it does |
| --- | --- |
| `none` | No isolation |
| `pin` | ROS nodes and llama-server on `--model-cores` (default 0-7), stressor on `--stress-cores` (default 8-11) |
| `prio` | SCHED_FIFO priority `--rt-prio` (default 50) on decision nodes and llama-server; needs `sudo -v` before the run |
| `pin_prio` | Both |

llama-server's affinity and priority are restored at the end of every run.

**Telemetry per run** (in `runs_summary.csv`): number of decisions, context switches per second
(from `/proc/stat`), and cache and branch misses from `perf stat -a` when `perf` is available
(otherwise `NA`). jtop data goes to `resources_<run_id>.csv`, node output and `run_info.txt`
(full configuration) to `logs/<run_id>/`. Join everything in JMP on `run_id`.

### A whole block: `scripts/run_campaign.sh`

Runs every configuration of a plan file, with repetitions, one after another. A failed run is
logged and the campaign continues.

```bash
scripts/run_campaign.sh plans/b1_baseline.plan --csv campagna.csv --dry-run   # list + time estimate
scripts/run_campaign.sh plans/b1_baseline.plan --csv campagna.csv --shuffle
scripts/run_campaign.sh plans/b1_baseline.plan --csv campagna.csv --skip-done # resume after an interruption
```

`--shuffle` randomizes the run order (as in a DOE, it avoids confusing a time trend with a
factor effect). Plan format, one configuration per line:

```
# systems      stress        level  isolation  reps  duration_s  freq_hz
semif          mem_stream    4      none       3     180         2
```

| Plan | Content | Runs | Estimated time |
| --- | --- | --- | --- |
| `plans/b1_baseline.plan` | SemIf and Gemma alone | 10 | about 1 h 20 min |
| `plans/b2_frequency.plan` | SemIf at 1, 3, 5 Hz | 9 | about 35 min |
| `plans/b3_colocation.plan` | SemIf + Gemma together | 5 | about 1 h |
| `plans/b4_interference.plan` | SemIf: 7 stressors x 2 levels; Gemma: 4 stressors | 54 | about 4 h 30 min |
| `plans/b5_isolation.plan` | pin / prio / pin_prio on the most harmful stressors | 27 | about 2 h 20 min |

## Run

Start the model servers first (wait until they are loaded):

```bash
# Gemma 4 31B Q8 (main generative arm)
lama serve -hf unsloth/gemma-4-31B-it-GGUF:UD-Q8_K_XL -ngl 99 -c 4086 -fa on -np 1 --reasoning-budget 0 --host 127.0.0.1 --port 8080 --metrics --swa-ful

```


## CSV columns (`runs.csv`)

- **Factors:** `system`, `run_id`, `freq_hz`, `interference`, `interference_level`, `isolation`,
  `colocation`, `repetition`, `prompt_cache`
- **Responses:** `e2e_ms` (sensor sample to decision), `queue_ms`, `infer_ms`,
  `prefill_ms` (SemIf: its single forward pass), `decode_ms` (0 for SemIf), `n_prompt_tokens`, `n_output_tokens`,
  `dropped` (cumulative samples skipped while busy), `correct`, `confidence` (SemIf only)

Timestamps come from `time.monotonic_ns()` in every process (CLOCK_MONOTONIC), so
`resources_*.csv` can be aligned with `runs.csv` via `t_mono_ns`.
