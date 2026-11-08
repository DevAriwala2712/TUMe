# T2.2 Diagnostic Admission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal**. Admit optional local diagnosis only when live resources and containment are available.

**Architecture**. A pure admission module handles parsing and memory/pressure decisions. The runner handles lifecycle and captures output while its Linux implementation binds checks and cleanup to a preconfigured cgroup.

**Tech stack**. Zig 0.15.2 and Linux cgroup v2.

**Spec**. `docs/superpowers/specs/2026-11-08-diagnostic-admission-design.md`.

## Global constraints

- Preserve `nanoclaw-next` identifiers and independent T1 monitoring.
- Use synthetic fixtures and static Linux cross-builds. Native trials require explicit authorization.

## Review focus

- Malformed and missing measurements must cause refusal.
- The tightest ancestor, including `memory.high`, limits admission.
- Runtime loss of reserve must trigger cleanup.
- Output overflow and externally canceled requests must discard output.
- An unconfirmed cleanup must override a successful backend status.

### Admission

- [ ] Write tests in `src/diagnostic/admission.zig` for strict parsers and ancestor, host, and runtime reserve behavior.
- [ ] Run `zig test src/diagnostic/admission.zig -target aarch64-macos.15.0` and confirm the new interfaces are missing.
- [ ] Implement `pressure(bytes)`, `limit(bytes)`, and `check(measurements, budget, phase)`.
- [ ] Rerun the tests and confirm they pass.

### Backend lifecycle

- [ ] Write tests in `src/diagnostic/runner.zig` for admission refusal, pressure, cancellation, deadline, shared capture cap, and cleanup failure.
- [ ] Run `zig test src/diagnostic/runner.zig -target aarch64-macos.15.0` and confirm the lifecycle interface is missing.
- [ ] Implement `run(allocator, config, argv, canceled)` using `runSession`, the Linux implementation in `src/diagnostic/linux_runner.zig`, and the child filter in `src/diagnostic/linux_backend_filter.zig`.
- [ ] Run `zig test src/tests.zig -target aarch64-macos.15.0`. Cross-build x86_64 and aarch64 Linux to verify native code.
- [ ] Record prerequisites, model-free VM results and pending workload acceptance in `docs/evidence/T2.2-diagnostic-admission.md`.
- [ ] Pass the T2.2 files to the milestone owner for the requested commit and push.
