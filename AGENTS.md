# Working on TUMe

TUMe is the maintenance-product spin-off; NanoClaw-Next is the upstream research project. Read `README.md`, `docs/PRODUCT.md`, `docs/ARCHITECTURE.md`, `docs/PLAN.md` and `docs/PROVENANCE.md` before changing product behavior.

- Distinguish inherited research capabilities from planned maintenance features. Do not claim a monitoring daemon, portal, autonomous repairs or cyberattack detection exists until implemented and evaluated.
- Preserve `nanoclaw-next` executable/configuration identifiers until a deliberate runtime migration. Do not globally rename source strings as cosmetic branding.
- Monitoring must remain useful without an LLM. Generated text and untrusted logs never grant execution permissions.
- Keep privileged recovery behind explicit procedures/policy, with bounded retries, verification and audit.
- Report full-system overhead and task quality. Historical inference success/RSS figures are not product acceptance.
- Do not start inference benchmarks, stress experiments, VMs or model downloads without explicit user authorization. Documentation-only work uses static document/repository checks.
- Do not publish ignored runtime state, model weights or credentials. Adopt upstream changes selectively and record their source/evidence.
