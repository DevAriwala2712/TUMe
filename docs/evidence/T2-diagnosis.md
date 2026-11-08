# T2 diagnosis validation

T2 adds an optional bounded incident timeline and model-free next checks, diagnostic admission in a dedicated cgroup, and an explanation protocol for a fresh T1 measurement. The model can propose an immediate cause from a closed vocabulary. The explanation checks that cause and its citation against the exact input and carries no execution authority.

## Native smoke

The arm64 Ubuntu 24.04.5 VM ran model-free smoke checks on Linux 6.8.0-147-generic, systemd 255, ext4, and cgroup v2. The combined Zig suite passed all 73 tests. ReleaseSmall built for Linux arm64 and x86_64. The incident smoke observed a failed disposable unit, scoped journal metadata and a linked episode after watcher restart. The native admission fixture verified refusals, limits, cancellation, descendant cleanup and job reuse after abort. The [explanation smoke](../../deploy/diagnostic/smoke-explanation.sh) used a real watcher report and accepted the matching citation, rejected a fabricated one and confirmed the leaf was empty after each invocation. The continuous watcher published a later sample during a deliberately stalled fake backend that the runner timed out.

## Acceptance

| Gate | Evidence required | Status |
|---|---|---|
| Timeline correctness and retention | Replay sample transitions, duplicates, gaps, target or release changes, hostile journal metadata and capacity or publication failures. Inspect evidence IDs, deterministic next checks and excluded log text. | Portable fixtures and arm64 VM smoke passed |
| Diagnostic admission and isolation | Use a fake backend on a designated Linux host. Verify missing measurements, refusals, hanging children, cancellation, output caps, and a job cgroup free of descendants after completion or abort. Check that the watcher keeps publishing. | Lifecycle fixtures and arm64 delegated cgroup smoke passed |
| Grounding and diagnosis usefulness | Run held-out, labeled scenarios against a pinned preinstalled model and backend. Count correct immediate causes, valid citations, unsupported claims, refusals and time. Compare with model-free next checks. | Contract fixtures and arm64 fake-backend smoke passed. Held-out model evaluation pending. |
| Full-device impact | Measure idle, startup, active and aborted phases. Include backend and descendants, cgroup and host measurements, persistence and protected workload latency and delivery. | Pending designated device and workload |

The [operator protocol](../operations/grounded-explanations.md) describes the first acceptance trial. Upstream inference measurements are recorded separately and do not enter these results. [Source and evidence provenance](../PROVENANCE.md)
