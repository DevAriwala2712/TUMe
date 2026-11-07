# Architecture direction and module boundaries

Status: T1 implements local observation, deterministic checks and bounded latest-report state. The remaining boundaries describe planned product work.

## Boundaries

| Logical module | Responsibility | Boundary |
|---|---|---|
| Observation collector | Bounded snapshots of system resources, selected services and relevant events | Read-only by default; report unsupported/unreadable inputs; bound sampling, retention and input size |
| Deterministic checks | Turn observations into defined health/overload findings | Works offline without an LLM; explicit thresholds, evidence and deduplication |
| Resource policy | Admit, defer, limit or stop optional diagnostic work | Protect the primary workload; include model children and optional connectors in the budget |
| Inference adapter | Run a selected backend/model when a diagnostic task fits | Reuse validated upstream methods; persistent-engine integration is future work |
| Diagnostic explanation | Summarize findings and propose next checks or a procedure identifier | Evidence references and uncertainty; no execution authority |
| Runbook engine | Validate and execute explicitly permitted procedures | Separate privileges; typed arguments, preconditions, limits, audit, verification and rollback/failure handling |
| State/audit store | Keep observations, findings, decisions and action outcomes | Bounded retention; deterministic identifiers and protected operator settings |
| API and portal | Expose device status, findings and authorized action workflows | Authentication/authorization, cancellation and audit before remote mutation |
| Optional adapters | Import security alerts, send notifications or connect to fleet/update tooling | Opt-in, independently budgeted, explicit permissions; no core dependency on every integration |

## Current source map

- `src/edge/`: inherited memory probing, GGUF parsing, cost estimates, scheduler, subprocess wrapper and llama.cpp command adapter.
- `src/runtime/`: inherited executable allowlist, timeout and rollback journal. These are not the proposed product privilege boundary or verified recovery engine.
- `src/app.zig`, `src/main.zig`: inherited `nanoclaw-next` CLI, with early dispatch to the T1 health command group.
- `src/health/`: T1 collector, bounded probe helpers, findings, report and local watcher. See the [operator guide](operations/linux-health.md).
- Historical memory/skill scaffolding is not a functioning maintenance subsystem.

Keep existing executable/configuration identifiers stable until a separately reviewed runtime change deliberately migrates them.

## Intended flow

1. Collect a bounded observation and retain its provenance.
2. Evaluate deterministic checks and emit or update a finding.
3. If useful and affordable, admit an explanation task with a model/context and output budget; otherwise retain the finding without an AI answer.
4. Return an explanation with evidence references and uncertainty.
5. For a proposed operational change, resolve a registered procedure and apply operator permissions. The model cannot create permissions.
6. Record the action, verify the outcome, and apply its defined failure/rollback policy. A successful command exit alone does not establish that a fault was repaired.

Privileged operations should live behind a narrow boundary rather than giving an LLM process unrestricted host access. Log text, API input and adapter events are untrusted data. Detailed interfaces, storage choices, thresholds, privilege mechanisms and supported runbooks must be specified for each implementation milestone; this document does not pretend those decisions are already implemented.
