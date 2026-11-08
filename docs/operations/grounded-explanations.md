# Requesting a grounded explanation

The optional explanation command reads the T1 watcher's latest report. It accepts one open finding at a time and requires a fresh, currently breached measurement. Run the command as the owner of the health state, typically the unprivileged `tume-health` account. That account also needs permission to use the dedicated diagnostic cgroup. The watcher can continue collecting when explanations are unavailable.

Use the `evidence_key` displayed by `health status`. For example, request a current finding for a failed gateway service.

```sh
sudo -u tume-health /usr/local/bin/nanoclaw-next health explain --config /etc/tume/health.json \
  --policy /etc/tume/diagnostic.json --finding service:gateway.service
```

Use [the policy example](../../deploy/diagnostic/policy.example.json) as a schema reference. Its resource values are examples. Replace them with a measured peak for the exact model, context and backend, and a reserve sized for the protected workload. The backend and cgroup must be provisioned by the operator. Use an unprivileged diagnosis identity, a preinstalled local model, and an executable and configuration protected from unintended modification. Never place secrets in the invocation.

The [llama-completion adapter](../../deploy/diagnostic/llama-explain.sh) is a starting configuration for a CPU-only, single-threaded backend. Review the paths, pin and record the installed llama.cpp revision, set a measured resource budget, and install a copy as the executable in policy. The adapter receives only the bounded schema 1 request with the rule, observation ID, timestamp and typed value. It does not read journal messages, user prompts or repair configuration. The protocol is `BACKEND --max-tokens N --request-json JSON`. Standard output must contain a single object with integer `schema_version` 1, an allowed `cause`, and a `citation` matching the request's evidence ID. [llama.cpp completion documentation](https://github.com/ggml-org/llama.cpp/tree/master/tools/completion)

A successful result exits 0 and reports the immediate possible cause, the cited sample and a deterministic next check. The cause is constrained to the evidence available in the sample. A refusal, missing observation, contradictory cause, invalid output or runner failure returns an inconclusive JSON result and exit 3. Exit 2 reports invalid usage or configuration. These results carry no recovery authority.

## Acceptance trial

On a disposable Ubuntu VM with an `ubuntu` account, systemd, ext4 and cgroup v2, run `sudo bash deploy/diagnostic/smoke-explanation.sh --disposable-vm /absolute/path/to/nanoclaw-next` to verify the full CLI with a model-free backend. The script uses temporary state, a disposable failing unit and a dedicated test cgroup.

The portable fixtures check the allowed candidate mapping, citation equality, refusals and policy validation. On the designated Linux host, run the diagnostic runner with a model-free test backend before trying a real model. Exercise valid, hung, invalid, oversized and interrupted responses, and verify the watcher continues to publish. Record exact fixture inputs, response status, empty diagnostic cgroup and any failed cleanup.

Before a real model trial, freeze the backend, model revision, context and task set. For a first held-out set, label at least two true breaches for each rule family, include both failed and inactive service states, and include at least two insufficient-evidence cases. Require correct immediate cause and a valid citation in at least 90% of sufficient-evidence cases, zero unsupported accepted claims, and an inconclusive outcome for every insufficient-evidence control. Record per-fault response, correctness, refusals, time and total cost per correct diagnosis. Compare operator usefulness and elapsed time against deterministic next checks. Report full-device idle, startup, active and aborted measurements and protected workload latency and delivery against a paired baseline. Select a trial-specific time and resource budget before running. These are proposed acceptance criteria. Model and workload trials require a designated test environment.
