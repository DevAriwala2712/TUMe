# TUMe

**A maintenance supervisor in development for Linux edge devices.**

TUMe aims to observe device health, protect the main workload from resource pressure, explain faults using evidence, and eventually perform explicitly permitted recovery procedures. Local LLM inference is an optional, budgeted capability; monitoring must remain useful when no model can run.

**Status: product incubation.** T1 implements read-only Linux health snapshots, a local watcher and deterministic findings. The arm64 Linux VM deployment smoke passed. The x86_64 native smoke and physical-device pilot are pending. T2 adds local incident history, deterministic next checks and an optional diagnostic job. Model-free diagnostic smoke passed on the arm64 Linux VM. Held-out model evaluation and workload measurements are pending. T3 implements verified recovery for one disposable systemd service, with operator approval by default. An HTTP API, a portal and integrations remain planned.

## Two repositories, two goals

| Project | Responsibility |
|---|---|
| **[NanoClaw-Next](https://github.com/DevAriwala2712/NanoClaw)** | Research memory-efficient local inference while measuring task usefulness, quality, latency and failures |
| **TUMe** | Develop the operational maintenance product, permissions, evidence-based diagnosis, recovery, API and integrations |

Start with the [product scope](docs/PRODUCT.md), [architecture and module boundaries](docs/ARCHITECTURE.md), [product roadmap](docs/PLAN.md), and [source/evidence provenance](docs/PROVENANCE.md).

## What is available now

The inherited Zig CLI can read memory and GGUF model metadata, estimate resource costs, choose configured model/context candidates, calibrate from measured runs, and retry some backend failures. It drives an external llama.cpp process. Its binary, configuration filename and commands are still named **`nanoclaw-next`**; a TUMe-branded runtime has not been introduced.

| Capability | Current status |
|---|---|
| Memory snapshots, model estimates, scheduler, calibration, research benchmark CLI | Inherited implementation; see the [historical runtime README](README.nanoclaw-next.md) |
| Allowlisted command execution and hard timeout | Inherited experimental path; commands run with the user's permissions, not kernel isolation |
| Linux device/service snapshots, watcher and latest findings | T1 implementation. See the [operator guide](docs/operations/linux-health.md) and [validation status](docs/evidence/T1-linux-health.md). |
| Incident history and evidence timelines | Optional local history and deterministic next checks. See the [incident guide](docs/operations/incident-history.md). |
| On-demand diagnosis | Optional cgroup-bounded explanations from fresh T1 observations. See the [explanation guide](docs/operations/grounded-explanations.md) and [validation status](docs/evidence/T2-diagnosis.md). |
| Bounded recovery procedures and auditing | One registered disposable service, with a separate executor and independent functional verification. A root-owned policy can opt in to automatic recovery within one boot. [Operator guide](docs/operations/verified-recovery.md) |
| HTTP API and web portal | Planned |
| Security-event adapters and suspicious-activity explanations | Planned; not a validated cyberattack detector |
| Fleet, messaging and maintenance/update integrations | Later candidates, not current features |

## Run local health checks

On Linux with Zig 0.15.2, build the binary and take a snapshot with the sample configuration.

```sh
zig build -Doptimize=ReleaseSmall
./zig-out/bin/nanoclaw-next health snapshot --config deploy/systemd/health.example.json
```

See the [operator guide](docs/operations/linux-health.md) for systemd deployment, status, and configuration.

## Intended operating model

```text
Device observations -> deterministic checks and resource policy -> findings
                                                        |
                                   budgeted LLM explanation, when useful
                                                        |
                           recommendation -> permitted runbook -> verification
```

The model proposes an explanation or procedure identifier; it does not authorize arbitrary commands. Initial product milestones focus on read-only observations and recommendations before autonomous changes.

## Using the inherited research runtime

Use **Zig 0.15.2**, external llama.cpp and suitable GGUFs for inference. Linux is the initial product target; the inherited code has macOS research support. The [historical README](README.nanoclaw-next.md) and [Zig requirements](ZIG_VERSION_REQUIREMENT.md) contain build instructions and the macOS SDK workaround.

```bash
zig build -Doptimize=ReleaseSmall
./zig-out/bin/nanoclaw-next probe
./zig-out/bin/nanoclaw-next plan --available-mb 1200
```

Model paths and a backend command must be configured to plan real candidates. These commands are **not** a TUMe maintenance-service installation. The inherited `run` command can execute generated allowlisted tools; do not treat it as a validated autonomous repair agent.

## Evidence and next step

Inherited benchmark reports concern NanoClaw-Next's inference experiments. Their 54-run memory grid and earlier cgroup OOM comparison do not measure a maintenance daemon, attack detection, diagnosis correctness or full-system overhead. See [benchmark provenance](docs/benchmarks/README.md).

The next milestone gate is a Linux deployment smoke test and a physical-device pilot measuring findings, whole-service overhead and broker performance. See the [product roadmap](docs/PLAN.md).
