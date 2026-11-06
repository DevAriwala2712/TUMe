# Spec: TUMe direction, competitive position, and the v0.1 health-and-findings core

Status: **draft for owner review** · Date: 2026-11-06 · Type: documentation only. No code, benchmark, VM or model download was run to produce it.

This spec does two things: (1) decides what to **keep, add, defer and cut** given the competitive landscape, and (2) specifies the first phase (T1 in [PLAN.md](PLAN.md)) in PRD form. Nothing here claims a TUMe feature exists. See [PRODUCT.md](PRODUCT.md), [ARCHITECTURE.md](ARCHITECTURE.md), [PLAN.md](PLAN.md) and [PROVENANCE.md](PROVENANCE.md) for the baseline it builds on.

**Evidence caveat.** Competitor information comes from web-search snippets, mostly vendor or comparison blogs, gathered in one session. The Netdata and Raspberry Pi documentation pages were not reachable (network allowlist), so those claims are secondhand. Items marked *(unverified)* come from general knowledge, not from this session's research. Verify before any external use.

---

## 1. Where TUMe sits

### 1.1 Competitive landscape

| Category | Examples | What they do well | Gap relevant to TUMe |
|---|---|---|---|
| Lightweight host monitoring | [Netdata](https://learn.netdata.cloud/docs/edge-device-monitoring), Prometheus node_exporter + [Grafana Alloy](https://grafana.com/docs/alloy/latest/monitor/monitor-linux/), Monit *(unverified)*, systemd restart/watchdog *(unverified)* | Mature collectors and dashboards. Netdata documents a Raspberry Pi 3 B+ example using under 1% of a core and about 30 MiB with a reduced schedule (vendor figure). Netdata also reports per-metric unsupervised ML at the edge and, since 2.6.0, MCP so AI assistants can query metrics | They show *what* changed. They do not explain *why* from cited evidence, and they do not carry out a verified fix. Metrics and anomaly detection are commodity |
| Fleet and device management | [balena, Mender, Memfault](https://pinggy.io/amp/blog/best_remote_iot_device_management_software/), Raspberry Pi Connect *(unverified)* | OTA updates, remote access, fleet dashboards. Memfault focuses on field stability and release impact | Update and fleet tools assume connectivity, a cloud backend, or a container or OTA model. They do not do on-device diagnosis |
| AI SRE and runbook automation | [Datadog Bits AI SRE](https://www.helpnetsecurity.com/?p=350215) (GA Dec 2025), PagerDuty, Rootly, Shoreline | Alert investigation, root-cause suggestions, runbook execution. Commentary stresses that runbook automation is not autonomous remediation and recommends human approval for first-seen incident classes | Built for cloud and server fleets: needs a connected backend, per-investigation cost, large models. Not designed for a 1–4 GB offline box where the diagnostic model competes with the workload |
| Security and intrusion detection | [CrowdSec, Wazuh](https://pimylifeup.com/raspberry-pi-crowdsec/), Falco *(unverified)* | CrowdSec runs on a Pi 5 (64-bit OS) and needs bouncers to block. Wazuh's manager is heavy (about 4 GB RAM suggested for a small homelab), while its agent is light | Established, with community data. TUMe cannot out-detect them. It could consume their alerts and explain them |
| Upstream research | NanoClaw-Next (this repo's origin) | Memory probe, GGUF cost model, model/context scheduler, calibration, hard-kill subprocess. The 54-run grid shows RSS estimates within 0.0583% on one VM | Inference-resource evidence, not maintenance-task quality |

### 1.2 What is commodity and what is not

- **Commodity, so do not compete:** metric collection, dashboards, threshold alerts, ML anomaly scores, "AI can query my metrics" (MCP).
- **Not well served on small, offline devices:** evidence-cited diagnosis that runs locally, bounded and audited recovery, and a **budget that protects the main workload**. That includes the diagnostic model's own memory.
- **TUMe's defensible position:** *a maintenance supervisor that stays useful with no LLM and no network, explains faults by citing its own measurements, and acts only through permitted, verified, audited procedures, all inside a declared whole-system budget.* This is a hypothesis. [PRODUCT.md](PRODUCT.md) already says superiority is unproven.

### 1.3 Strategic risks

1. **Deterministic monitoring is a crowded layer.** Netdata and Alloy do it better today. Mitigation: build only the checks the diagnosis and recovery loop needs, and design input adapters so Prometheus, Netdata or journald data can be consumed later instead of rebuilt.
2. **Small-model diagnosis may not be accurate enough.** The upstream finding M-4 (a 360M model wrote a wrong command for "show free disk space") is the warning sign. Mitigation: T2 exits only on a held-out diagnostic suite with predefined limits on wrong claims. Recommendations come from deterministic rules first, and the LLM only explains.
3. **Autonomous recovery is the liability.** Mitigation: recommend-only first, per-procedure opt-in, and a privilege boundary before any automatic action.
4. **Footprint credibility.** A small controller binary says nothing about total cost. Mitigation: count collectors, model children, state and adapters. Report idle and active separately.

---

## 2. Keep / Add / Defer / Cut

### Keep (inherited or already decided)

| Item | Why |
|---|---|
| Product principles in [PRODUCT.md](PRODUCT.md): useful without an LLM, untrusted logs, no generated-text authority, evidence discipline | These are the differentiator against LLM-first tools |
| `src/edge/sysmem.zig` (Linux meminfo, cgroup v2, PSI parsing) | Directly reusable as the memory collector and resource-policy input |
| `src/edge/proc.zig` (hard-kill timeout, peak-RSS capture) | Reusable for running diagnostic children and runbook steps within limits |
| Scheduler, estimator and calibration (`src/edge/`) | Becomes the **admission policy for optional diagnosis jobs**. This is the real reuse of the research work |
| Executable allowlist and rollback journal (`src/runtime/`) | Starting material for the runbook engine. **Not** a privilege boundary, per ARCHITECTURE.md |
| `nanoclaw-next` binary and config identifiers | Do not rename until a deliberate migration |
| Staged T0–T6 roadmap and the "honest status report" exit criteria | Keeps claims tied to evidence |

### Add (new capabilities, in priority order)

| Priority | Capability | Phase |
|---|---|---|
| P0 | Bounded collectors: memory and PSI, CPU load, disk and inode capacity, temperature, selected systemd unit state and restart counts, recent journal errors | T1 |
| P0 | Deterministic findings with stable IDs, severity, evidence references, dedupe and flap suppression | T1 |
| P0 | Local read-only CLI (`status`, `findings`) with machine-readable JSON output | T1 |
| P0 | **Self-accounting:** TUMe reports its own RSS, CPU and collection time, and fails safe when over its own budget | T1 |
| P0 | Explicit "unsupported / unreadable / permission denied" reporting per input | T1 |
| P0 | Fixture-based test corpus of fault scenarios (log and `/proc` replays), the base of later diagnosis evaluation | T1 |
| P1 | Raspberry Pi and SBC health checks: undervoltage and throttle flags, SD/eMMC wear and I/O errors, time sync, link and connectivity loss *(candidate checks; hardware-specific, need validation on a real device)* | T1+ |
| P1 | Bounded retention store (ring or SQLite-class) for observations, findings and decisions | T1+ |
| P1 | Export of findings and metrics as JSON, a Prometheus textfile or journald, so TUMe coexists with existing stacks | T1+ |
| P1 | Local notification hook (webhook or command) for new or escalated findings | T2 |
| P1 | On-demand diagnosis with citation validation, an uncertainty field, and refusal when evidence is thin | T2 |
| P1 | Recommend-only runbook registry with dry-run output | T3 |
| P2 | Read-only MCP or JSON-RPC surface for findings (parity with Netdata, and agent interoperability) | T4 |
| P2 | Import of alerts from Falco, CrowdSec or Wazuh, and ingestion of Prometheus or Netdata data | T5 |
| P2 | Signed and versioned runbooks, per-procedure auto-enable policy | T3+ |

### Defer (valuable, but not before the foundations are validated)

Web portal (API first), fleet enrollment and views, messaging channels (Slack, Telegram), update orchestration (integrate Mender or balena, do not build), persistent llama.cpp engine integration (upstream M4 work), thermal-aware model scheduling.

### Cut or freeze

| Item | Reason |
|---|---|
| General-assistant features: `src/memory/hierarchy.zig`, `src/skills/`, `src/tools/fallback.zig` | The upstream audit calls them scaffolding. Do not extend. Candidates to remove after T1 so they are not mistaken for product features |
| Cloud-model fallback | Conflicts with offline and privacy positioning. If ever added, opt-in and never for device logs by default |
| "Cyberattack detection" claims | No detector or evaluation exists. Describe only as "explain imported alerts" until measured |
| Building an inference engine, a SIEM or an OTA updater | Out of scope per PRODUCT.md. Integrate existing tools |
| Competing on binary size | Upstream finding 7: the harness is small next to everything else |

---

## 3. PRD: v0.1 read-only device health and findings (T1)

### Problem statement

Operators of Linux edge boxes (gateways, Raspberry Pi-class computers) running a primary workload under tight RAM learn about memory pressure, a full disk, an overheating board or a crash-looping service only after the workload fails. Generic monitors need a backend or a dashboard, and AI-assisted tools assume the cloud. Unattended devices fail without a trustworthy local record of *what happened and on what evidence*. Not solving it leaves TUMe a research runtime with no product behavior.

### Goals

1. **Detect** a documented set of resource and service faults deterministically, with no model and no network. Success: fixture scenarios yield the expected findings with no false positives on healthy fixtures.
2. **Stay cheap and prove it.** Total TUMe footprint (processes, state) stays under a declared budget on the chosen reference device, and TUMe reports it. Targets are proposed in section 6 and need owner approval.
3. **Be honest about blind spots.** Every unavailable or unreadable input is reported, never silently skipped.
4. **Produce evidence-linked findings** that T2 diagnosis and T3 recovery can later consume without schema changes.
5. **Never harm the workload.** Collection is read-only and bounded, and it backs off under pressure.

### Non-goals

- No LLM inference, diagnosis or explanation (T2), because deterministic value must be proven first.
- No remediation, restarts or privileged actions (T3), because the privilege boundary does not exist yet.
- No HTTP API, portal or fleet features (T4, T6), because local CLI and JSON are enough to validate findings.
- No security or intrusion detection (T5), because it needs labeled data and evaluation.
- No rename of `nanoclaw-next` identifiers, because migration is a separate reviewed change.

### User stories

**Edge operator (Pi/gateway owner)**
- As an operator, I want to run one command and see current memory, disk, temperature and service status, so that I can judge device health without installing a monitoring stack.
- As an operator, I want a finding such as "memory pressure sustained, top consumers listed" with the measurements that triggered it, so that I can verify it myself.
- As an operator, I want repeated or flapping conditions merged into one finding, so that I am not buried in duplicates.
- As an operator, I want to be told when TUMe cannot read a sensor or service (permissions, missing hardware), so that I do not assume "no finding" means "healthy".
- As an operator, I want TUMe to report its own memory and CPU use, so that I can trust it is not the cause of the problem.

**Integrator / SRE**
- As an integrator, I want findings as stable JSON with IDs, severity and evidence references, so that I can pipe them into existing alerting.
- As an integrator, I want the agent to run with no network and no model present, so that it works on isolated devices.

**TUMe developer**
- As a developer, I want a replayable fixture corpus of fault scenarios, so that every check and later diagnosis can be regression-tested without real hardware faults.

### Requirements

**Must-have (P0)**

| # | Requirement | Acceptance criteria |
|---|---|---|
| R1 | Collect memory (MemAvailable, swap, cgroup limits, PSI), CPU load, disk and inode usage, temperature where exposed, and the state and restart count of a configured list of systemd units | Given fixture `/proc`, `/sys` and `systemctl` outputs, then snapshots match golden files. Given an unreadable or absent input, then the snapshot lists it with a reason and the rest still completes |
| R2 | Deterministic checks for: sustained memory pressure, low disk or inodes, high temperature, unit failed or crash-looping | Given a fault fixture, then exactly the expected finding is produced with threshold, observed value and evidence references. Given a healthy fixture, then no finding is produced. Thresholds are configurable and documented |
| R3 | Finding lifecycle: stable ID, first and last seen, severity, open or resolved state, dedupe, flap suppression | Given a condition that oscillates around a threshold, then one finding is updated, not N created. Given recovery, then the finding resolves after a documented hysteresis |
| R4 | Read-only CLI: `status` and `findings`, human and JSON output | JSON validates against a published schema. The commands perform no writes outside the state directory and invoke no privileged operations |
| R5 | Bounded resources: capped sampling rate, input size, retention and process count | Per-input read size limits are enforced (for example an oversized journal excerpt is truncated and flagged). Retention evicts oldest data at the cap |
| R6 | Self-accounting: report TUMe's own RSS, CPU time and collection duration | `status` shows these values. Given collection exceeding its time budget, then it is aborted and flagged. Given TUMe above its memory budget, then it degrades (slower sampling) and raises a finding about itself |
| R7 | Operates with no model, no network and no external backend | Test environment with network blocked and no model configured completes all R1–R6 acceptance tests |
| R8 | Untrusted input handling: log and unit text are data only | Given a fixture log line containing instructions or shell metacharacters, then it appears escaped as evidence and triggers no execution and no change in findings logic |

**Nice-to-have (P1)**

| # | Requirement | Acceptance |
|---|---|---|
| R9 | Raspberry Pi and SBC checks (undervoltage and throttle flags, SD/eMMC errors, time sync, connectivity) | Each check documents its source, is skipped with a reason when unsupported, and is validated on at least one physical device before being called supported |
| R10 | Persistent bounded state store surviving restarts | Findings and history survive a restart. Store size stays under the configured cap |
| R11 | JSON, Prometheus textfile or journald export of findings and self-metrics | Output parses with the target tool's reader |
| R12 | Packaging as a systemd service with sandboxing directives | Service starts and stops cleanly, runs as a non-root user for read-only checks, and documents which files it reads |

**Future considerations (P2): design for, do not build**

- Finding and evidence IDs that T2 prompts can cite and a validator can check.
- A stable "procedure identifier" field on findings (empty in v0.1) so T3 can attach runbooks without a schema change.
- A plug-in input interface for Prometheus, Netdata, Falco or CrowdSec data.
- A read-only MCP or HTTP surface over the same JSON.

### Success metrics

*Proposed targets, not achieved results. The owner must approve them, and they need a baseline on the reference device first.*

| Type | Metric | Proposed target |
|---|---|---|
| Leading | Fixture scenarios with the correct finding | 100% of the defined set. Zero findings on healthy fixtures |
| Leading | Inputs reported as unsupported or unreadable instead of silently dropped | 100% in the permission and missing-sensor fixtures |
| Leading | Steady-state TUMe RSS and CPU on the reference device | Hypothesis: ≤ 16 MiB RSS and ≤ 1% of one core at the default interval. Context: Netdata's vendor example is about 30 MiB on a Pi 3 B+. Replace with a measured figure and declare a budget before implementation |
| Leading | Collection overhead on the protected workload | No measurable regression beyond a pre-declared tolerance, measured under a representative load |
| Lagging | Unattended days without TUMe-caused resource violations or crashes on a pilot device | Set after pilot design (for example ≥ 14 days). Requires a physical device |
| Lagging | Operator-confirmed useful findings vs noise in pilot | Set threshold with pilot users. Needs 5–8 real operator interviews (the upstream research flags this gap) |

Evaluate fixtures at each commit. Evaluate overhead and pilot metrics at the T1 exit review.

### Open questions

| Question | Owner | Blocking? |
|---|---|---|
| What is the reference device and protected workload (Pi 4/5, which RAM, which service)? | Owner | **Blocking** for budgets and thresholds |
| Zig single binary vs. small helper processes for collectors? Which keeps total footprint lower? | Engineering | Blocking for architecture, resolve in design |
| Which units and which journal sources are in scope for v0.1, and how are they configured? | Engineering / owner | Non-blocking |
| Persistent store choice (flat ring file, SQLite, other) and its footprint | Engineering | Non-blocking for P0 |
| Who are 5–8 real operators for interviews and a pilot? | Owner | Non-blocking, but needed before T2 priorities are firm |
| License and distribution plan (PROVENANCE.md notes no license file) | Owner / legal | Non-blocking for T1, **blocking** for external release |
| Should v0.1 introduce a `tume` binary alias, or stay `nanoclaw-next` for now? | Owner | Non-blocking. Default: keep `nanoclaw-next` |
| Is Linux-only (systemd) acceptable for v0.1? | Owner | Non-blocking. Assumed yes per PRODUCT.md |

### Timeline and phasing

No external deadlines are known. Dependencies are the reference-device decision (blocking) and access to a physical device for R9 and the pilot.

1. **T1a: foundations.** Decisions on reference device, budget and schema. Then R1, R2, R4, R7, R8 with the fixture corpus.
2. **T1b: lifecycle and accounting.** R3, R5, R6, then a footprint measurement report on the reference device.
3. **T1c: P1.** R9–R12 if the T1 exit criteria are met.
4. **T1 exit review.** Publish an honest status report: findings correctness, overhead, failure behavior. Then decide T2 scope based on interview and pilot evidence.

**Parking lot (explicitly not in v0.1):** T2 diagnostic model selection, runbook registry, portal, fleet, security adapters, assistant-style features.

---

## 4. Recommended next actions

1. Owner decides the reference device and workload, plus the footprint budget (blocks everything).
2. Run 5–8 operator interviews in parallel with T1a to test the "diagnosis plus bounded recovery" hypothesis. This is the weakest-evidenced premise.
3. Open an ADR for the collector process model (single binary vs helpers).
4. After T1 merges, remove or clearly label inherited assistant scaffolding.
5. Re-run this competitive check before T2. The AI SRE and edge-monitoring space is moving fast, and the sources used here are secondhand.

## Sources

- [Netdata edge device monitoring](https://learn.netdata.cloud/docs/edge-device-monitoring) (via search snippet; page not fetched)
- [Grafana Alloy: monitor Linux](https://grafana.com/docs/alloy/latest/monitor/monitor-linux/)
- [Remote IoT device management comparison (balena, Mender, Memfault)](https://pinggy.io/amp/blog/best_remote_iot_device_management_software/)
- [Datadog Bits AI SRE announcement](https://www.helpnetsecurity.com/?p=350215)
- [Top AI SRE tools overview](https://neubird.ai/blog/top-ai-sre-tools)
- [CrowdSec on Raspberry Pi](https://pimylifeup.com/raspberry-pi-crowdsec/)
- [Self-hosting Wazuh](https://selfhosted-sh.pages.dev/wazuh-siem-self-hosted)
