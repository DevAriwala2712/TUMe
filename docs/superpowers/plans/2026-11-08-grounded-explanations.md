# Grounded Explanations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal**

Expose on-demand, local, evidence-checked explanations for one current T1 finding.

**Architecture**

Build a typed request from the health store, run a single optional diagnostic job through T2.2, and validate the proposal before constructing a report. Render deterministic next checks even when the backend declines.

**Tech stack**

Zig 0.15.2, Linux cgroup v2, versioned JSON.

**Spec**

[Grounded explanations](../specs/2026-11-08-grounded-explanations-design.md)

## Global constraints

Keep the existing CLI identifiers and health schema. Bound the input and output. Treat configuration as local operator input and backend responses as untrusted. A request never confers recovery authority.

## Review focus

An old report, hysteresis, an unavailable measurement, a fabricated evidence ID or a response that contradicts the current measurement must produce an inconclusive result. A policy with zero budgets, nonnumeric limits or an executable without an absolute path must be rejected.

### Task 1 · Evidence and response contract

- [x] Add tests in `src/diagnostic/explanation.zig` for all four rules, mismatched evidence, unsupported causes and coverage gaps. Register the module in `src/tests.zig`.
- [x] Run the explanation tests with Zig and observe missing implementation.
- [x] Implement request construction from `state.Loaded` and strict validation of the bounded response in `src/diagnostic/explanation.zig`.
- [x] Rerun fixtures and exercise a true positive and rejection for each rule family.

### Task 2 · Local CLI and evaluation handoff

- [x] Add policy fixtures for typed fields, hard bounds and invalid executable paths.
- [x] Add `src/diagnostic/cli.zig` and dispatch `nanoclaw-next health explain --config PATH --policy PATH --finding EVIDENCE_KEY` before research configuration loading.
- [x] Call the runner only for fresh, evaluable findings. Emit a structured result for each admission or backend outcome.
- [x] Run the full portable suite and cross-build Linux arm64 and x86_64. Document native fake-backend trials, held-out diagnosis and footprint gates separately.
