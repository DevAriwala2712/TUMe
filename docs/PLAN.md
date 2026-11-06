# TUMe product roadmap

Updated: 2026-11-06. This roadmap is a sequence of product milestones, not a claim that the maintenance features exist. The archived [NanoClaw-Next plan](RESEARCH_PLAN.md) is inherited research context, not this product's implementation plan.

## T0 — Establish the product and provenance

Repository identity, independent README, product scope, architecture, staged roadmap, source lineage and benchmark labeling. Preserve the inherited research code/history. No new runtime behavior, inference experiments or model downloads are part of T0.

## T1 — Read-only device health

Collect bounded Linux resource/service snapshots and emit deterministic findings for a small documented set of conditions. Include memory pressure, disk capacity and selected service failures; report missing permissions/sensors. Define the initial target device/workload and collection/retention budgets before implementation.

Exit: fixture-defined findings are correct; collection overhead and failure behavior meet the chosen budget; observation works without any model or network service. Publish an honest status report.

## T2 — Useful, budgeted diagnosis

Provide on-demand explanations grounded in selected findings/log excerpts. Admit inference only within a declared budget; defer when it would threaten the protected workload. Evaluate stronger/smaller model choices for diagnostic correctness and refusal behavior, using upstream research rather than assuming model fit implies quality.

Exit: a held-out diagnostic suite meets predefined correctness and unsupported-claim limits; evidence references are valid; monitoring remains available during inference failure and budget exhaustion.

## T3 — Explicitly permitted recovery

Add a small registry of maintenance procedures with typed arguments, permissions, preconditions, retry/rate limits, verification and audit records. Start with operator-approved actions; consider automatic recovery only for individually enabled procedures after validation. Implement a narrow privilege boundary before claiming safe autonomous administration.

Exit: permitted repairs succeed on defined fault scenarios; forbidden/unsupported actions are rejected; verification distinguishes repair from command completion; rollback/failure behavior and repeated-fault handling are demonstrated.

## T4 — API and web portal

Expose device state, findings, evidence, budgets, proposed procedures and action outcomes. Include authentication/authorization, bounded inputs, cancellation and audit for mutation. Keep the portal optional for headless use. Define endpoints and UI flows in a milestone design before implementation.

Exit: operators can diagnose and authorize supported actions through a consistent API; access boundaries hold; whole-system footprint remains within the declared target.

## T5 — Security-event and maintenance adapters

Evaluate integration with existing event/security tools and update systems rather than building every detector or updater. Begin with read-only event import and explanation. Measure false positives, missed labeled events and diagnostic usefulness before making cyberattack-detection claims. Updates and network-policy changes need separately scoped procedures and authorization.

Exit: each adapter has a documented input contract, permissions, bounded overhead, failure behavior and an evaluated operator use case.

## T6 — Fleet and selected integrations

Add only validated needs: device enrollment/identity, fleet views, notification channels or update orchestration. Keep connectors opt-in and account for their child processes and persistent storage. General assistant feature parity is not a completion criterion.

Exit: the supported device/workload scale, authorization boundaries, failure recovery and total resource budgets are measured and documented.

## Cross-cutting acceptance

- Count the full footprint: controller, collectors, models, adapters, isolation and persistent state. Report idle and active operation separately.
- Report correct diagnoses/repairs, false/unsupported recommendations, refusals, resource violations, end-to-end latency and availability of the protected workload.
- Monitoring and deterministic emergency policies work without an LLM. Operational authority comes from explicit policy, not generated text.
- No physical Pi validation, security accuracy, continuous supervision or product RAM target is yet established by inherited inference benchmarks.
- Feature implementation requires its own design and verification; the current setup does not start those milestones or run new experiments.
