# TUMe

**A planned lightweight maintenance supervisor for Linux edge devices.**

TUMe aims to observe device health, protect the main workload from resource pressure, explain faults using evidence, and eventually perform explicitly permitted recovery procedures. Local LLM inference is an optional, budgeted capability; monitoring must remain useful when no model can run.

**Status: product incubation.** This repository preserves NanoClaw-Next's existing research runtime and Git history. The TUMe maintenance daemon, health collectors, incident diagnosis, recovery procedures, HTTP API, web portal and integrations are **not implemented yet**. No TUMe product performance, security-detection accuracy or unattended-recovery results are claimed.

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
| Continuous device/service health monitoring and incident records | Planned |
| On-demand diagnosis grounded in logs and telemetry | Planned |
| Bounded recovery procedures, permissions, auditing and rollback | Planned |
| HTTP API and web portal | Planned |
| Security-event adapters and suspicious-activity explanations | Planned; not a validated cyberattack detector |
| Fleet, messaging and maintenance/update integrations | Later candidates, not current features |

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

The first implementation milestone is a read-only Linux health snapshot and findings pipeline with bounded collection overhead. Feature breadth follows validated usefulness and a declared total memory budget; see [docs/PLAN.md](docs/PLAN.md).
