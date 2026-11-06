# Product scope

Decision date: 2026-11-06. Product name: **TUMe**. The owner chose a separate maintenance-product effort while retaining NanoClaw-Next for research. The spelling TUMe was selected from the delegated alternatives TUMe/TUMMe; no acronym expansion is asserted.

## Purpose

Help operators of Linux gateways, Raspberry Pis and small computers understand device problems and keep the main workload running under constrained RAM and intermittent connectivity. The first target is a Linux edge computer, not microcontroller firmware. No physical-device product validation has been completed.

TUMe's intended advantage is useful diagnosis and bounded recovery within a whole-system resource budget. A tiny controller binary does not establish a tiny operational footprint: collectors, inference children, integrations, persistent state and isolation all count.

## Product principles

- Always-on observations and deterministic checks remain useful without an LLM.
- The protected workload has priority over diagnostic inference. Budget exhaustion may defer or refuse an explanation.
- Findings link to actual measurements and events, with uncertainty separated from evidence.
- Logs and other device data are untrusted; embedded text never becomes an execution instruction.
- Model/context selection must account for task usefulness, not only successful text generation. Small-model mistakes observed upstream remain relevant.
- Operational changes use identified procedures, typed arguments, permissions, retry/rate limits, verification and audit records. Initial behavior is read-only; automatic actions require a later explicit policy.
- Adoption of a research optimization requires a recorded source version and product-specific validation.

## Feature priorities

| Priority | Feature | What would count as useful |
|---|---|---|
| First | Memory/CPU/disk/temperature and selected service observations | Bounded collection; missing permissions and unsupported sensors reported explicitly |
| First | Deterministic overload and service-failure findings | Evidence-backed findings that do not require inference |
| Next | On-demand diagnostic explanations | Operator can inspect cited events, uncertainty and recommended next checks |
| Next | Resource policy for optional AI jobs | Monitoring survives model unavailability; diagnostics cannot starve the protected workload |
| After foundations | Approved recovery procedures | Scoped action, preconditions, bounded retries, verification, audit and failure/rollback handling |
| After foundations | API and portal | Consistent device/finding/action records, authentication and explicit authorization boundaries |
| Later | Security-event interpretation | Consume defined events/alerts; measure false positives and evidence quality before making detection claims |
| Later | Messaging, fleet, updates and external integrations | Clear operator use case, optional loading and a measured overhead budget per integration |

No numerical idle-RAM, accuracy, fleet-size or latency target is claimed as achieved. Define workload-specific budgets and acceptance thresholds before implementing and evaluating each milestone.

## Position among existing tools

[NanoClaw](https://github.com/nanocoai/nanoclaw) is a fuller assistant with integrations and container isolation; feature parity is not the initial TUMe objective. [llama-server](https://github.com/ggml-org/llama.cpp/tree/master/tools/server), [Ollama](https://docs.ollama.com/faq) and [llama-swap](https://github.com/mostlygeek/llama-swap) already provide model-serving/lifecycle capabilities. TUMe should integrate suitable infrastructure rather than rebuild it without an operational need.

[Falco](https://falco.org/docs/) and [Mender](https://docs.mender.io/overview/introduction) occupy relevant runtime-security and device-management areas. Security/update adapters are candidates, not shipped integrations. TUMe's potential distinction is constrained local operation plus useful diagnosis and bounded recovery; superiority is unproven.

## Outside the initial scope

A general-purpose assistant suite, unrestricted autonomous administration, a new LLM inference engine, a complete endpoint-security replacement, autonomous fleet-wide patching, and guaranteed detection of cyberattacks. These exclusions keep the first product reviewable; future scope decisions need evidence and an operator use case.
