# T1 Linux health validation

**Pilot status: pending.** The proposed reference system is a physical Raspberry Pi 4 Model B with 2 GiB RAM, running 64-bit Raspberry Pi OS Lite and a protected Mosquitto broker. The paired trial, live fault injection and systemd smoke test require designated test hosts. The [T1 design](../superpowers/specs/2026-11-07-linux-health-design.md) defines the test order, workload, sample counts and thresholds.

## Implementation checks

- Model-free Zig fixture tests cover config validation, parsing, thresholds, probe lifecycle, JSON, restart cadence, atomic replacement and freshness.
- The CLI and test binaries cross-compile for Linux arm64 and x86_64. The macOS CLI smoke test checks the explicit Linux-only health response.
- On 2026-11-08, the native smoke checklist passed at commit `e09a0c4` on an arm64 Multipass guest with Ubuntu 24.04.5 LTS, Linux 6.8.0-147-generic, systemd 255, cgroup v2, ext4 and Zig 0.15.2. The checklist's architecture assertion was set to `aarch64` for this run.
- `zig build test --summary all` passed all 46 tests, including the Linux-native helper and disk fixtures. The snapshot, missing and fresh status, incompatible configuration, and private state mode checks passed.
- `systemd-analyze verify` and the installed unit smoke passed. The dedicated service account ran the watcher, the status report was fresh and used schema 1, and the unit stopped with no tasks remaining. The x86_64 native smoke and physical Pi pilot are still pending.

## Remaining acceptance

| Gate | Target or check | Result |
|---|---|---|
| Linux installation | Verify the unit with `systemd-analyze verify`, check an unprivileged start and fresh schema 1 status, stop it and verify no remaining helpers | Passed on arm64 Ubuntu VM. x86_64 native smoke pending. |
| Linux integration fixtures | Run `zig build test` on a designated Linux host, including helper exit, timeout, output cap and symlink rejection | 46/46 passed on arm64 Ubuntu VM |
| Model-free and offline | Run the Pi watcher with no model and disconnected backhaul. Check local observations and explicit source/freshness failures | Pending |
| Whole-service memory | ≤ 16 MiB p95 cgroup memory and ≤ 32 MiB peak with all helpers included | Pending |
| CPU and sampling | ≤ 1% of one core on average, ≤ 1,000 ms collection p95, no overlapping samples | Pending |
| Disk | ≤ 128 KiB status and temporary payload, report installed and journal bytes separately | Pending |
| Protected MQTT workload | Zero missing deliveries and OOM kills, p95 publish-to-ack increase ≤ the larger of 1 ms or 5% of paired baseline | Pending |
| Findings under fault | Disposable unit opens within 35 s after a stop and clears within 35 s after recovery, while the broker stays available | Pending |
| Comparison | Record Monit settings and comparable Netdata settings, correctness, time to alert and full footprint under the same workload | Pending |

Run the paired trial and disposable service check only after the device and workload are authorized. Publish the measured values, variance, failure cases and pass/fail by gate. Keep credentials, local runtime state and model artifacts out of the evidence commit.
