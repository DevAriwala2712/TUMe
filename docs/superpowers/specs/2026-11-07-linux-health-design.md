# TUMe T1 Linux device health design

[Product scope](../../PRODUCT.md) · [Roadmap](../../PLAN.md) · [Market review](../../MARKET.md)

## Outcome and approaches

An operator of a small Linux gateway can see why its device needs attention while disconnected, with no model installed. A sample should show measured values, partial coverage, and which configured service or filesystem needs investigation. A sustained incident should survive a watcher restart and stop reporting as current when observation stops.

- **Small native core plus adapters (proposed).** Use Zig for a narrow set of local checks and a stable status contract. Use external tools for broad telemetry, alert routing and OTA. This gives TUMe control over local failure semantics and resource accounting.
- **Wrapper around an existing monitor.** Netdata or Monit would supply broad coverage sooner. This is a useful baseline or integration for customers already running them. Reconsider a wrapper if TUMe's native collector cannot meet the budget or the pilot shows that normalization and support workflows matter more than the local core.
- **Fleet service first.** Enrollment and remote status would improve multi-site visibility. Start that work after single-device evidence, staleness and storage semantics are proven. [Market review](../../MARKET.md)

The proposed pilot is a physical Raspberry Pi 4 Model B with 2 GiB RAM, 64-bit Raspberry Pi OS Lite (record the image, kernel and systemd versions before evaluation), unified cgroup v2 and a protected Mosquitto workload. Linux arm64 is the product target. Linux x86_64 is a smoke-test target. Both assume systemd and a local ext4 filesystem for T1. The existing macOS research commands keep their current behavior.

## Global constraints

- Zig 0.15.2. Use Zig's standard library and Linux interfaces. Add zero third-party runtime libraries or packages to the T1 core.
- Preserve the `nanoclaw-next` binary and `nanoclaw-next.conf` research configuration. Dispatch the new `health` group before loading the research app or config.
- Health needs no model, credentials, network service, elevated account or privileged command. No logs, arbitrary executable paths, external alerts, remote listeners or repairs in T1.
- Use bytes, integer basis points (0–10,000) and signed millidegrees Celsius. JSON uses schema version 1 and stays at or below 65,536 bytes including the newline.
- Poll every 15 seconds using a monotonic clock. Allow one external probe at a time, at most 250 ms per probe, and at most 1,500 ms per collection attempt. Skip missed ticks.
- Bound configuration to 4,096 bytes, proc/sys reads to 8,192 bytes per file, and probe stdout and stderr to 4,096 bytes combined. Allow one local mount, four distinct systemd service units and one optional temperature sensor.
- Keep persistent status bounded to 131,072 bytes including one temporary status file. Use a local owner-only state directory. Keep only the latest report and the current per-check counters.
- Tests use fixture inputs and model-free fakes. Obtain explicit authorization before inference benchmarks, stress experiments, VMs or model downloads. Schedule the physical pilot with an approved device and workload.

## Operator contract

All public commands require `--config PATH` with the same strict JSON document. The file can specify only `mount` (required, absolute local directory, no symlink or dot segments, max 256 bytes), `services` (array of up to four exact ASCII unit names of up to 128 bytes matching `[A-Za-z0-9_.@-]+[.]service`, no leading dash or duplicates, default empty), `thermal_zone` (optional integer 0–255, null by default) and `state_dir` (absolute local directory, same path limits as `mount`, required for watch/status). Reject malformed, duplicate or unknown keys. Treat config and the state directory's parent as operator-controlled. Ship a separate example. The installed service uses a dedicated user and a systemd-created state directory. Use `/etc/tume/health.json` in the example deployment, with `state_dir` set to `/var/lib/tume`.

| Command | Behavior |
|---|---|
| `nanoclaw-next health snapshot --config PATH` | Print one versioned JSON report with observations and current breaching checks. Read only. The snapshot does not create or read persisted incident state. |
| `nanoclaw-next health watch --config PATH` | Take the first eligible sample, then follow the monotonic schedule. Update confirmed findings and publish the latest report locally. Stop on SIGTERM/SIGINT. |
| `nanoclaw-next health watch --config PATH --once` | Perform one eligible watch iteration with the same lock and persistence path, then exit. Exit 0 without publishing when a fresh matching sample is less than 15 seconds old. |
| `nanoclaw-next health status --config PATH` | Return the last watch report with freshness. An absent, stale, invalid or incompatible report returns an explicit status instead of a healthy report. |

Exit 0 when a snapshot is emitted or status is fresh, even with findings or partial coverage. Exit 2 for usage, invalid config or unsupported OS. Exit 3 for unavailable status, unavailable sample identity or clock, lock contention or an unsuccessful `watch --once` write. A long-running watcher survives a failed publish and sends a reason to stderr no more than once per five minutes. Health dispatch on macOS returns exit 2 and reports `health requires Linux`.

## Observations and findings

Every configured source has a fixed evidence key and a typed value or a reason in `unsupported`, `denied`, `unavailable`, `invalid`, `timeout`, `truncated`. Known failed units are different from an unavailable query. Do not copy raw stderr, env, or raw file content to status.

| Evidence key | Source and meaning |
|---|---|
| `host.memory` | `MemTotal` and `MemAvailable` from `/proc/meminfo`. Both required, in kB, checked before converting to bytes, with total > 0 and available ≤ total. A missing field stays unknown. |
| `host.memory_psi`, `host.cpu_psi` | `some avg10` from `/proc/pressure/memory` or `/proc/pressure/cpu`. Convert finite decimals in the range 0–100% to basis points, rounding to nearest with ties upward. CPU PSI measures stalled time. [Linux PSI documentation](https://docs.kernel.org/accounting/psi.html) |
| `disk.mount` | Capacity of the one configured local ext4 directory. For `used = blocks - bfree`, compute `floor(10000 × used / (used + bavail))` with wide integer intermediates. Reject zero denominator and inconsistent block counters. Check filesystem type before using counters. |
| `service:<unit>` | Read systemd's load and active states using fixed argv and `/usr/bin/systemctl show --no-pager --property=LoadState --property=ActiveState -- UNIT` with `LC_ALL=C`. A valid `LoadState=not-found` response means unsupported even with a nonzero exit. Other nonzero responses are unavailable. A loaded unit's active states are active, inactive, failed, activating, deactivating or reloading. Other states are unavailable for T1. |
| `sensor.temperature` | If configured, read `/sys/class/thermal/thermal_zoneN/temp`. Accept signed integers in the range −40,000 to 150,000 m°C. A missing configured sensor is unsupported. If unconfigured, omit the evidence key. |

For disk, systemd and thermal probes, use a process-group-isolated helper, nonblocking pipes, a monotonic deadline and nonblocking reap. The one-probe limit applies per invocation. For the installed service, keep all descendants in the service cgroup and use systemd control-group termination and a task cap of eight. Kill the group on timeout, oversize output, or shutdown. If the kernel has not reaped a killed child, report subsequent external probes unavailable until it is reaped. Parent collection of kernel memory and PSI observations can continue. Run disk path resolution inside the helper using no-symlink component traversal. Resolve the opened descriptor’s mount ID to its filesystem type in the Linux mount table, then read capacity using the same descriptor. Cap the mount table read at 65,536 bytes. Reject non-ext4 mounts and report truncated or unavailable mount metadata explicitly. Stop starting probes once the attempt deadline is reached and cap each probe by the time remaining. Trusted state storage must be local ext4. An uninterruptible state I/O stall may stop publication, so readers use freshness and never infer continuing health. Do not use the inherited `proc.run` wrapper as a hard isolation guarantee.

| Rule ID | Subject and evidence | Breach | Recovery |
|---|---|---|---|
| `memory_headroom_low` | `host`, `host.memory` | available < 128 MiB | available ≥ 160 MiB |
| `memory_stalled` | `host`, `host.memory_psi` | some avg10 ≥ 1,000 bp | some avg10 < 500 bp |
| `disk_capacity_high` | configured mount, `disk.mount` | used ≥ 9,000 bp | used ≤ 8,500 bp |
| `service_unavailable` | configured unit, `service:<unit>` | failed or inactive | active |

Between thresholds, during service transitions, or when source evidence is missing, keep the confirmed state and reset consecutive counts. Use two consecutive breaches to open and two consecutive recovery observations to close. Schedule from the last eligible attempt start on Linux CLOCK_BOOTTIME. An attempt less than 15,000 ms after the previous accepted sample leaves the report and streaks unchanged. A gap of at least 30,000 ms resets streaks before evaluating the new sample. A restart or manual one-shot follows the same rules. Use a new timestamp at each eligible attempt start and never count a sample twice. An open finding retains its first-open timestamp, current evidence reference and whether its current input is evaluable. A valid numeric reading in the deadband is evaluable. A transitional unit state or missing source is unevaluable. Sort evidence by bytewise key and findings by bytewise rule ID, then subject. A stable finding key is the tuple `(rule_id, subject)`; no unbounded episode history in T1.

### JSON and freshness

A report contains `schema_version`, `mode` (`snapshot` or `watch`), `boot_id`, `sampled_at_unix_ms`, `sampled_at_boot_ms`, `collection_ms` (boot-clock elapsed time before rule evaluation and persistence), `target` (the canonical configuration tuple), `observations` and `findings`. Observations are a sorted array of `{key, value, reason}` with exactly one of `value` and `reason` non-null. Memory uses `{total_bytes, available_bytes}`, PSI and disk use `{basis_points}`, temperature uses `{millidegrees_c}` and service uses `{active_state}`. Findings use `{rule_id, subject, evidence_key, opened_at_unix_ms, input_evaluable}`. A snapshot uses its sample time for instantaneous findings. Persisted watch reports additionally include private `streaks` keyed by rule and subject, with breach and recovery counts capped at two. Exclude streaks from CLI output. Limit the encoded report including private fields to 61,440 bytes so the public status envelope also fits its cap.

`status` outputs `{schema_version, freshness, report}`. Use `fresh` with a report, or `absent`, `stale`, `invalid`, `incompatible` or `unavailable` with a null report. Use unavailable for state access failures. Freshness describes the age and identity of the report. Observation reasons still indicate missing coverage in a fresh report. Treat undecodable state, a malformed report or negative same-boot age as invalid. A valid envelope with an unsupported schema version or different target tuple is incompatible. A different boot or age of at least 45,000 ms is stale.

## Storage and deployment

Use one owner-only lock for the watcher and atomically replace `latest.json` using a same-directory temporary file, file sync, rename and directory sync. Use 0700 for the state directory and 0600 for files. Reject state file and lock symlinks, non-regular state files, an unexpected owner and non-private directories. Readers see one complete version. If a write fails before rename, retain the old report. If it fails after rename, report uncertain durability; on restart load either complete report. A live watcher continues its in-memory evaluation when publishing fails. A missing, corrupt or incompatible file resets state and receives its corresponding freshness reason. Resume counters and open findings only from a fresh same-boot report for the same configured subjects and sensor. Otherwise reset state. Both readers and writers check the canonical configuration tuple of mount, bytewise-sorted unit names and thermal zone. Config order and state path do not affect this tuple. A mismatch is incompatible. Wall time is for display only.

Use one private, unprivileged systemd service with local state, `NoNewPrivileges=yes`, a restrictive umask, stop bounded by systemd, and no restart storm. Use a 3-second stop timeout, a 5-second restart delay and at most three starts per 60 seconds. No HTTP service, no separate database and no privileged install step within the health CLI. Document how to install, query and remove the service. Operators query under the service UID or using host administrative access. The systemd deployment must still permit the read-only system bus query and configured sensor access. Deploying the service is separate from validating it on target hardware.

## Acceptance for the proposed pilot

Compare the protected Mosquitto broker alone with the same setup plus TUMe. Use loopback QoS 1 with one subscriber, 256-byte payloads and ten publications per second. Use three 30-minute pairs in baseline/TUMe, TUMe/baseline, baseline/TUMe order, after five minutes of warmup per run. Configure the root mount, the broker, a disposable test unit, two ordinary system units and the onboard thermal sensor. Record every unit and whether each probe had coverage. Use the same measurement observer in both variants. Sample whole-service cgroup memory once per second and record `memory.peak`, `cpu.stat`, `memory.events`, writable state and journal bytes, collection durations, and broker delivery and acknowledgment latency. Use numbered messages to count missing and duplicate deliveries. Include helpers, service cache, and startup peaks. Record device/image, sample counts, command versions, limits, and raw measurements with secrets removed. Report p95 via nearest rank. Report installed bytes and measured journal growth even where no independent cap is set.

| Measure | Proposed gate, per paired run unless stated |
|---|---|
| Agent footprint | ≤ 16 MiB p95 cgroup memory and ≤ 32 MiB cgroup peak. Include the complete agent service tree. |
| CPU and time | ≤ 1% of one logical core on average; collection p95 ≤ 1,000 ms. No overlapping samples. |
| Persistent state | ≤ 128 KiB total report and temporary report payload. Report service journal growth separately. |
| Protected workload | Zero dropped messages and OOM kills; p95 publish-to-ack increase ≤ the larger of 1 ms or 5% of the paired baseline. |
| Task behavior | Correct open/close outcomes on fixture sequences for all four rules. Live stopped disposable service opens within 35 seconds and clears within 35 seconds of becoming active; the protected broker stays running. No fabricated health after lost access, disconnected network or stale state. |

Run an x86_64 Linux install/status smoke test and a no-network/no-model run on the Pi. Compare like-for-like CPU, memory, time-to-alert and operator usefulness against Monit and, where setup is comparable, Netdata. Publish measurements and variance with pass/fail against the predeclared thresholds. Keep T1 unvalidated until the required evidence exists. Treat new runs and any fault injection as separately authorized work.
