# T1 Linux health validation

**Pilot status: pending.** The proposed reference system is a physical Raspberry Pi 4 Model B with 2 GiB RAM, running 64-bit Raspberry Pi OS Lite and a protected Mosquitto broker. The paired trial, live fault injection and systemd smoke test require designated test hosts. The [T1 design](../superpowers/specs/2026-11-07-linux-health-design.md) defines the test order, workload, sample counts and thresholds.

## Implementation checks

- Model-free Zig fixture tests cover config validation, parsing, thresholds, probe lifecycle, JSON, restart cadence, atomic replacement and freshness.
- The CLI and test binaries cross-compile for Linux arm64 and x86_64. The macOS CLI smoke test checks the explicit Linux-only health response.
- Native Linux probe tests and the systemd install, status and stop checks are pending. Cross-compilation establishes target compatibility at build time.

## Remaining acceptance

| Gate | Target or check | Result |
|---|---|---|
| Linux installation | On x86_64, verify the unit with `systemd-analyze verify`, check an unprivileged start and fresh schema 1 status, stop it and verify no remaining helpers | Pending |
| Linux integration fixtures | Run `zig build test` on a designated Linux host, including helper exit, timeout, output cap and symlink rejection | Pending |
| Model-free and offline | Run the Pi watcher with no model and disconnected backhaul. Check local observations and explicit source/freshness failures | Pending |
| Whole-service memory | ≤ 16 MiB p95 cgroup memory and ≤ 32 MiB peak with all helpers included | Pending |
| CPU and sampling | ≤ 1% of one core on average, ≤ 1,000 ms collection p95, no overlapping samples | Pending |
| Disk | ≤ 128 KiB status and temporary payload, report installed and journal bytes separately | Pending |
| Protected MQTT workload | Zero missing deliveries and OOM kills, p95 publish-to-ack increase ≤ the larger of 1 ms or 5% of paired baseline | Pending |
| Findings under fault | Disposable unit opens within 35 s after a stop and clears within 35 s after recovery, while the broker stays available | Pending |
| Comparison | Record Monit settings and comparable Netdata settings, correctness, time to alert and full footprint under the same workload | Pending |

Run the paired trial and disposable service check only after the device and workload are authorized. Publish the measured values, variance, failure cases and pass/fail by gate. Keep credentials, local runtime state and model artifacts out of the evidence commit.
