# Verified Recovery Implementation Plan

> **For agentic workers:** Use test-driven development with the implementation delegated under the T3 milestone. Steps use checkbox syntax for tracking.

**Goal:** Implement the operator-approved restart and verification of one registered disposable Linux service.

**Architecture:** The unprivileged CLI previews a typed procedure. A standalone sudo-authorized helper checks a root-owned policy, serializes attempts using one per-target lock, and records them in a bounded, atomically published audit. Fixed systemd commands and a peer-identified local functional probe operate behind the helper.

**Tech Stack:** Zig 0.15.2, Linux systemd, sudo, POSIX file locking and sync.

**Spec:** [T3 roadmap](../../PLAN.md#t3--verified-recovery) and [operator procedure](../../operations/verified-recovery.md).

## Global Constraints

- The only target is `tume-recovery-demo.service` at procedure revision 1.
- Approval is local, requires an authenticated operator and expires after five minutes on the same boot.
- One dispatch per approval, with no automatic retry or rollback. Unknown dispatch blocks new attempts until explicit reconciliation.
- Reserve audit capacity before dispatch. All durable intent publication steps precede the effect.
- Live privilege, Linux service trials and automatic recovery remain gated.

## Review Focus

- Exact typed target and identifier parsing reject lookalikes and injected options.
- A different actor, device, boot or expired token cannot dispatch a restart.
- Losing the caller after intent or receiving a nonzero dispatch result blocks new attempts until a read-only reconciliation.
- An active service with an incorrect functional reply remains unverified.
- Concurrent callers and insufficient audit capacity cannot dispatch twice.

## Tasks

- [x] Define failing fixtures in `src/recovery/tests.zig` for parsing, authorization, replay, crash ambiguity, verification, lock contention and audit capacity.
- [ ] Implement `src/recovery/procedure.zig` for exact typed arguments and preview, and `src/recovery/ledger.zig` for the locked, durable event file.
- [ ] Implement `src/recovery/engine.zig` for approval, dispatch, independent verification and reconciliation. Verify the fake backend sees a persisted intent.
- [ ] Implement `src/recovery/executor.zig` and `src/recovery/native.zig` for the Linux trust boundary and fixed native operations.
- [ ] Add the sudo policy and disposable systemd fixture, and document installation, audited operation and the authorized pilot protocol.
- [ ] Run the host fixtures and cross-compile both Linux targets. Publish the code at the T3 milestone.
