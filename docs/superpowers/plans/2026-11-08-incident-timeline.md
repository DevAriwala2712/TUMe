# Incident Timeline Implementation Plan

> **For agentic workers:** Use test-driven development and execute the tasks in order. The T2 integrator owns the milestone commit.

**Goal:** Give Linux operators a local timeline and evidence-linked next checks for T1 findings.

**Architecture:** Continuous watch publishes its T1 report first and hands eligible samples to a separate bounded history writer. The incident CLI independently reads and validates history, correlates optional journal metadata on request, and emits typed checks.

**Tech Stack:** Zig 0.15.2, Linux systemd, local ext4, SHA-256.

**Spec:** [T2.1 incident timeline and next checks](../specs/2026-11-07-incident-timeline-design.md)

## Global constraints

- Keep the T1 command, report, and private state contract and existing runtime identifiers.
- Retain at most 24 hours, 128 events and 128 KiB, with owner-only files and no automatic rewrite of invalid or unknown versions.
- Return up to 20 incidents or 16 detail events in 65,536 bytes. Use an independent 250 ms helper deadline.
- Keep raw journal messages, process arguments, environment values, cursors and stderr out of the results.

## Review focus

- Unknown readings and restart boundaries must never produce fabricated recovery.
- Evicting an opening must preserve the interpretation of retained evidence.
- Failed or uncertain durability must break continuity on the next successful write.
- Malformed, duplicate, and future history must remain untouched by the writer.
- Untrusted journal rows must never enter a report as raw text or influence findings.

## Task 1. Model the timeline

**Files:** `src/incident/timeline.zig`, `src/incident/tests.zig`, `src/health/types.zig`, `src/health/config.zig`.

- [x] Replay open, lost coverage, regained coverage, and resolution for all four T1 rules. Verify restart yields a linked new episode and deterministic IDs.
- [x] Implement `timeline.appendSample(allocator, prior, input)` using confirmed T1 before and after state, typed sample evidence, and boot-relative times.
- [x] Verify strict opt-in configuration, disk/time retention, duplicate and invalid history fixtures.

## Task 2. Integrate the isolated writer

**Files:** `src/incident/store.zig`, `src/incident/writer.zig`, `src/health/watch.zig`.

- [x] Verify owner-only atomic state, invalid/unknown file preservation, and pre-/post-replace failure semantics.
- [x] Implement history-only lock, private store read and replace, helper spawn/timeout/reap, and boundary propagation after failure.
- [x] Invoke the writer only after successful continuous-watch publication. Verify snapshot, status and watch-once compatibility and cross-build for Linux.

## Task 3. Expose incident views and journal metadata

**Files:** `src/incident/cli.zig`, `src/incident/journal.zig`, `docs/operations/incident-history.md`.

- [x] Verify list/detail response limits, evidence references, historical uncertainty, unknown IDs, and required configuration.
- [x] Implement `cli.run(allocator, args)` and metadata-only journal projection, with tests for malformed input, attribution, duplicate cursors, and timestamp windows.
- [x] Document usage and outstanding Linux deployment, whole-device, and operator validation gates.
- [x] Run static checks, host unit tests, and Linux release cross-builds. Hand off to the T2 integrator for the milestone commit.
