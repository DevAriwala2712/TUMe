# Source and evidence provenance

TUMe was established on 2026-11-06 at the owner's request as the maintenance-product spin-off of [DevAriwala2712/NanoClaw](https://github.com/DevAriwala2712/NanoClaw). NanoClaw-Next remains the research repository for memory-efficient inference with measured task usefulness.

## Source snapshot

- Source branch: NanoClaw `main`.
- Split commit: [`fe65c25e37dab1e1c572aabde08a56467008b952`](https://github.com/DevAriwala2712/NanoClaw/commit/fe65c25e37dab1e1c572aabde08a56467008b952).
- Git commit history is retained. Original GitHub issues, PR objects and release metadata are not migrated.
- TUMe is a separate same-owner repository with shared source ancestry. GitHub's same-account fork operation returned the original repository instead of creating `TUMe`; the spin-off was established as an independent repository with an `upstream` remote. Do not describe it as having a GitHub fork badge/network relationship that does not exist.
- The setup commits change repository identity/docs only. The inherited binary and config names remain `nanoclaw-next` / `nanoclaw-next.conf`.
- Some inherited CLI messages still reference pre-split milestone numbers, including isolation "planned, M3." Use TUMe's product roadmap for current ownership; no kernel isolation is implemented by that message.
- Ignored model files, credentials, VM state and local experiment output are not copied into GitHub.

## Inherited material

[README.nanoclaw-next.md](../README.nanoclaw-next.md), [RESEARCH_PLAN.md](RESEARCH_PLAN.md), [RESEARCH_SYNTHESIS.md](RESEARCH_SYNTHESIS.md), `Resources/` and `docs/benchmarks/` retain research history. They do not define implemented TUMe product functionality. The early research snapshot includes positioning and version statements that should not be treated as current competitive analysis or product requirements.

The benchmark evidence includes a memory-capped fixed-model comparison and a 54-observation quantization/context grid. These measured inference resource behavior on an Apple Silicon Mac/Ubuntu VM, not maintenance-task quality, attack detection, physical Pi performance or full-product overhead. Existing source test results are inherited records, not a newly executed TUMe acceptance suite.

## Moving improvements between projects

There is no live package dependency or automatic merge pipeline. Adopt relevant upstream changes selectively through a reviewed commit/cherry-pick or a future explicit interface. Record the source commit, supported configuration, evidence and product validation. Do not import experiments wholesale into an operational deployment.

The source snapshot contains no repository-level license file. This setup does not introduce or assume a new license; licensing is an explicit owner decision before broader distribution/reuse commitments.
