# T2.3 grounded explanations

An operator requests an explanation of one open T1 finding using the current, fresh watcher report. The deterministic incident command remains available to investigate older or incomplete evidence. The first explanation adapter accepts only typed, current measurements. It omits raw journal text and local configuration from the backend input. A later evidence contract can add redacted incident context.

The local operator supplies a diagnostic policy with an absolute executable, a measured peak and workload reserve, a dedicated cgroup, deadline, token limit and output cap. The executable receives a bounded request with a schema version, rule, timestamp and typed observations. It must implement the local backend protocol and honor the explicit token cap. It runs on demand through the isolated diagnostic runner.

The response contract admits a single candidate cause from a closed vocabulary and one citation for the selected observation. Check the citation against the request and test the candidate against the current measurement. Render observed values, uncertainty and next checks from known data. An open finding in hysteresis, missing or stale evidence, backend failure or contradictory output produces an inconclusive result with a specific reason. A candidate describes a supported immediate condition. The interface deliberately does not infer the root cause or authorize a procedure.

Offline fixture review checks all four rule families, stale and insufficient evidence, spoofed IDs, wrong field types and unsupported hypotheses. Real usefulness must be compared against deterministic next checks in authorized held-out trials. The pilot must also measure the whole-device impact and refusals against predeclared budgets.
