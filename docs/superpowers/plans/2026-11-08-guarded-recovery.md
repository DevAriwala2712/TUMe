# Guarded Recovery Implementation Plan

> **For agentic workers:** Use test-driven development for the delegated T3.3 implementation. Steps use checkbox syntax for tracking.

**Goal:** Allow root to opt the disposable demo into one guarded automatic start attempt per boot.

**Architecture:** A dedicated no-argument root executable reads a short boot-bound maintenance window and reuses the shared lock, audit, restart and verification engine. The audit latches the circuit on uncertain or failed automatic work.

**Tech Stack:** Zig 0.15.2, systemd, Linux BOOTTIME and ext4.

**Spec:** [Guarded recovery design](../specs/2026-11-08-guarded-recovery-design.md).

## Review Focus

Manual approval priority, post-intent revocation, precondition changes, stale windows after reboot, and an unverified result followed by a new policy.

## Tasks

- [x] Define failing tests for boot-bound windows, rate and circuit limits, manual priority, precondition drift and switch revocation.
- [x] Implement `engine.automatic`, the ledger transition, and shared dispatch revalidation.
- [x] Wire the separate root binary and optional inert deployment units. Add activation, kill-switch and reset instructions.
- [ ] Run host fixtures and a disposable native trial. Record the sanitized evidence.
