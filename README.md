# RTSIA Bench

Benchmark ROS 2 su Jetson AGX Orin: **SemIf** e **Gemma** ricevono gli stessi dati simulati; ogni decisione viene salvata in CSV. Eseguire i comandi in **Bash sulla Jetson**.

## 1. Installare ROS 2

Verificare JetPack e Ubuntu:

```bash
cat /etc/nv_tegra_release
. /etc/os-release && echo "$VERSION_ID ($VERSION_CODENAME)"
```

| JetPack / Ubuntu | ROS 2 | `ROS_SETUP` |
| --- | --- | --- |
| 6.x / 22.04 | Humble | `/opt/ros/humble/setup.bash` |
| 7.2.x / 24.04 | Jazzy | `/opt/ros/jazzy/setup.bash` |

Se JetPack non è configurato, seguire la [guida NVIDIA](https://docs.nvidia.com/jetson/agx-orin-devkit/user-guide/latest/quick_start.html). Per ROS 2, consultare la guida [Humble](https://docs.ros.org/en/humble/Installation/Ubuntu-Install-Debs.html) o [Jazzy](https://docs.ros.org/en/jazzy/Installation/Ubuntu-Install-Debs.html). Eseguire i blocchi seguenti nella stessa shell.

**Preparare i repository:**

```bash
export ROS_DISTRO=humble  # scegliere jazzy su Ubuntu 24.04
locale                   # verificare che la locale sia UTF-8
sudo apt update
sudo apt install software-properties-common curl
sudo add-apt-repository universe
```

**Aggiungere la sorgente ROS 2:**

```bash
ROS_APT_SOURCE_VERSION=$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest | grep -F '"tag_name"' | awk -F'"' '{print $4}')
curl -fL -o /tmp/ros2-apt-source.deb \
  "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")_all.deb"
sudo dpkg -i /tmp/ros2-apt-source.deb
```

**Installare e verificare ROS 2:**

```bash
sudo apt update
sudo apt upgrade
sudo apt install "ros-${ROS_DISTRO}-ros-base" ros-dev-tools python3-colcon-common-extensions
source "/opt/ros/${ROS_DISTRO}/setup.bash"
ros2 --help
```

Se la locale non è UTF-8 o `ros-dev-tools` ha conflitti su Ubuntu 24.04, seguire i passaggi di preparazione nella guida ROS scelta.

## 2. Ambiente Python e build

`requirements.txt` è nella radice di `RTSIA_project`; `rtsia_bench/` è il workspace `colcon`. Eseguire i blocchi seguenti nella stessa shell.

**Installare gli strumenti di sistema:**

```bash
sudo apt install python3-venv python3-pip libopenblas-dev git cmake build-essential \
  stress-ng rt-app rt-tests
```

**Creare e attivare il virtualenv:**

```bash
cd /percorso/del/repository/RTSIA_project  # sostituire con il percorso reale
export RTSIA_ROOT="$PWD"
export WS="$RTSIA_ROOT/rtsia_bench"
export VENV="$WS/.venv"
python3 -m venv --system-site-packages "$VENV"
source "$VENV/bin/activate"
source "/opt/ros/${ROS_DISTRO}/setup.bash"
```

**Installare le dipendenze Python:**

```bash
python -m pip install -r requirements.txt
```

**Compilare e verificare:**

```bash
cd "$WS"
colcon build --symlink-install
source "$WS/install/setup.bash"
python -c 'import torch, rclpy, rtsia_bench, semif_phase1; print("CUDA:", torch.cuda.is_available())'
```

`--system-site-packages` rende disponibili nel virtualenv i moduli ROS installati con `apt`. La verifica deve stampare `CUDA: True`; le versioni di PyTorch e CUDA fissate in `requirements.txt` richiedono un JetPack compatibile. Gli script avviano i nodi con il Python di `VENV`. Per comandi Python manuali in una nuova shell: `source "$VENV/bin/activate"`.

La telemetria richiede `jetson-stats` nel **Python di sistema**: seguire le [istruzioni del progetto](https://github.com/rbonghi/jetson_stats) e verificare con `/usr/bin/python3 -c 'from jtop import jtop'`.

## 3. Avviare Gemma

Rendere disponibile `lama` nella shell. In un terminale separato, avviare il server e attendere il caricamento:

```bash
# Gemma 4 31B Q8 (main generative arm)
lama serve -hf unsloth/gemma-4-31B-it-GGUF:UD-Q8_K_XL -ngl 99 -c 4086 -fa on -np 1 --reasoning-budget 0 --host 127.0.0.1 --port 8080 --metrics --swa-ful
```

Verificare in un altro terminale:

```bash
curl -f http://127.0.0.1:8080/health
```

Gli script sperimentali controllano il server, ma non lo avviano.

## 4. Eseguire le campagne

In **ogni nuova shell**, impostare i percorsi. **`R` deve essere definita dall'utente** e indica dove salvare i risultati:

```bash
cd /percorso/del/repository/RTSIA_project/rtsia_bench
export WS="$PWD"
export VENV="$WS/.venv"
export ROS_SETUP=/opt/ros/humble/setup.bash  # usare jazzy su Ubuntu 24.04
export R=/percorso/scelto/dall_utente/risultati  # OBBLIGATORIO: sostituire
```

**Controllare il piano:**

```bash
OUT_DIR="$R/b1" scripts/run_campaign.sh plans/b1_baseline.plan --csv b1.csv --dry-run
```

**Avviare la campagna B1:**

```bash
OUT_DIR="$R/b1" scripts/run_campaign.sh plans/b1_baseline.plan --csv b1.csv --skip-done --shuffle
```

`--skip-done` riprende la campagna e `--shuffle` mescola l'ordine dei run.
`--csv b1.csv` scrive le decisioni in `$R/b1/b1.csv`. Nella stessa cartella: `runs_summary.csv` (riepilogo dei run), `resources_<run_id>.csv` (telemetria), `logs/<run_id>/` e `campaign_*.log`.

**Singolo esperimento SemIf:**

```bash
OUT_DIR="$R/prova" scripts/run_experiment.sh --systems semif --duration 180 --csv prova.csv
```

**Singolo esperimento con entrambi i sistemi** (avviare prima Gemma):

```bash
OUT_DIR="$R/prova" scripts/run_experiment.sh --systems semif,gemma --duration 300 --csv prova.csv
```

`--systems` usa `semif`, `gemma` o `semif,gemma`. Per stress e isolamento sono disponibili `--stress`, `--level`, `--isolation`, `--model-cores` e `--stress-cores`; consultare `scripts/run_experiment.sh --help`. I piani `plans/b1_baseline.plan` fino a `b6_colocation_isolation.plan` e `plans/b8_rtapp.plan` coprono le diverse campagne.

## 5. Altri script e misure

| Script | Uso |
| --- | --- |
| `scripts/run_campaign.sh` | Esegue tutte le configurazioni di un piano. |
| `scripts/run_experiment.sh` | Esegue un solo run. |
| `scripts/resource_logger.py` | Registra CPU, GPU, RAM e potenza; viene avviato automaticamente. |
| `scripts/run_cyclictest.sh` | Misura la latenza del sistema senza modelli. |
| `scripts/parse_cyclictest.py` | Converte l'output di cyclictest in CSV. |

Il piano di cyclictest richiede `rt-tests` e `sudo`. Prima controllarlo:

```bash
OUT_DIR="$R/b9" scripts/run_cyclictest.sh plans/b9_cyclictest.plan --dry-run
```

Poi avviarlo:

```bash
OUT_DIR="$R/b9" scripts/run_cyclictest.sh plans/b9_cyclictest.plan --skip-done --shuffle
```

Le azioni sono `stop`, `slow_down` e `proceed`. Il CSV delle decisioni contiene `run_id`, `system`, `correct`, tempi (`e2e_ms`, `queue_ms`, `infer_ms`, `prefill_ms`, `decode_ms`) e `t_mono_ns`, usabile per allineare decisioni e telemetria.
