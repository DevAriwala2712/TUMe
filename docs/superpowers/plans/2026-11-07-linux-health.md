# TUMe T1 Linux Device Health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a Linux gateway operator read-only, evidence-backed device and service findings that work with no model or network.

**Architecture:** The existing binary dispatches a separate health command group before the research runtime is initialized. A Linux collector feeds pure rules, and a single unprivileged watcher publishes bounded state for a local reader. Disposable helpers contain slow probes and the protected workload remains separately measurable.

**Tech Stack:** Zig 0.15.2, Linux procfs/sysfs and local ext4, systemd, JSON, cgroup v2 for evaluation.

**Spec:** [T1 Linux device health design](../specs/2026-11-07-linux-health-design.md) · [Roadmap for T2–T6](../../PLAN.md)

## Global Constraints

- Zig 0.15.2. Use Zig's standard library and Linux interfaces. Add zero third-party runtime libraries or packages to the T1 core.
- Preserve the `nanoclaw-next` binary and `nanoclaw-next.conf` research configuration. Dispatch the new `health` group before loading the research app or config.
- Health needs no model, credentials, network service, elevated account or privileged command. No logs, arbitrary executable paths, external alerts, remote listeners or repairs in T1.
- Use bytes, integer basis points (0–10,000) and signed millidegrees Celsius. JSON uses schema version 1 and stays at or below 65,536 bytes including the newline.
- Poll every 15 seconds using a monotonic clock. Allow one external probe at a time, at most 250 ms per probe, and at most 1,500 ms per collection attempt. Skip missed ticks.
- Bound configuration to 4,096 bytes, proc/sys reads to 8,192 bytes per file, and probe stdout and stderr to 4,096 bytes combined. Allow one local mount, four distinct systemd service units and one optional temperature sensor.
- Keep persistent status bounded to 131,072 bytes including one temporary status file. Use a local owner-only state directory. Keep only the latest report and the current per-check counters.
- Tests use fixture inputs and model-free fakes. Obtain explicit authorization before inference benchmarks, stress experiments, VMs or model downloads. Schedule the physical pilot with an approved device and workload.

## Review Focus

1. An overflowing or incomplete meminfo field leaves memory unknown without falling back to `MemFree` or discarding valid PSI. Task 1.
2. A timed-out helper that remains unreaped blocks new helpers without blocking core observations or the next tick. Task 2.
3. A service query reporting `not-found` or a transient unit state cannot trigger an outage or clear an existing one. Tasks 2 and 3.
4. Rapid manual samples cannot count twice and a missed tick cannot bridge a two-sample threshold. Task 4.
5. A same-boot report for different configured targets is incompatible even when fresh, and an interrupted publish leaves a complete report or an explicit status error. Task 4.

---

## File map

| File | Responsibility |
|---|---|
| `src/health/types.zig` | Bounded config target, sample values, evidence reasons and timestamps |
| `src/health/config.zig` | Strict separate health config parsing and canonical target comparison |
| `src/health/collect.zig` | Linux observation parsers, bounded sample assembly and source classification |
| `src/health/probe.zig` | Linux child ownership, bounded read/deadline/reap and fixed filesystem/service/temperature probe implementation |
| `src/health/findings.zig` | Four deterministic rules, evidence and confirmation state |
| `src/health/report.zig` | Shared report model and public JSON encoding |
| `src/health/cli.zig` | Health commands, status envelope and exit contract |
| `src/health/state.zig` | Status freshness, lock, bounded persistence and atomic publication |
| `src/health/watch.zig` | Cadence, resume, signal handling and state lifecycle |
| `src/main.zig`, `src/tests.zig` | Existing command dispatch and test-root registration |
| `deploy/systemd/tume-health.service`, `deploy/systemd/health.example.json` | Unprivileged watcher unit and sample config |
| `docs/operations/linux-health.md`, `docs/evidence/T1-linux-health.md` | Deployment instructions, pilot protocol and authorized results |

Type names below belong to their listed module. Use a bounded allocator or per-operation arena for owned strings and JSON buffers. Config target strings live for the command. Per-sample storage is freed before the next sample. Linux-only system calls are compiled only on Linux. Keep fixture and policy tests portable. Task filters use `zig test src/tests.zig --test-filter 'tume health task n'`, with `n` matching the task.

### Task 1 — Health config and kernel observation contract

**Files**

- Create `src/health/types.zig`, `src/health/config.zig`, `src/health/collect.zig`.
- Modify `src/tests.zig` to import the config and collector test modules.

**Interfaces**

- `types.Target = struct { mount: []const u8, services: []const []const u8, thermal_zone: ?u8 }`. `types.Config = struct { target: Target, state_dir: ?[]const u8 }`.
- `types.Stamp = struct { boot_id: [36]u8, unix_ms: i64, boot_ms: u64 }`. Parse canonical Linux boot UUID and obtain time from the realtime and boot clocks. Never synthesize freshness from wall time.
- `types.Reason = enum { unsupported, denied, unavailable, invalid, timeout, truncated }`. `types.Reading(T)` is a tagged union with `value: T` and `reason: Reason`.
- `types.Memory = struct { total_bytes: u64, available_bytes: u64 }`. `types.ActiveState = enum { active, inactive, failed, activating, deactivating, reloading }`. `types.Service = struct { unit: []const u8, state: Reading(ActiveState) }`.
- `types.Sample = struct { stamp: Stamp, collection_ms: u64, memory: Reading(Memory), memory_psi_bp: Reading(u16), cpu_psi_bp: Reading(u16), disk_used_bp: Reading(u16), services: []const Service, temperature_mc: ?Reading(i32) }`. Service slice follows canonical target order. Absent temperature means unconfigured.
- `config.parse(allocator: std.mem.Allocator, bytes: []const u8) !Config`, `config.sameTarget(a: Target, b: Target) bool`. Config allocates from the caller's arena.
- `collect.stamp() !Stamp` reads `/proc/sys/kernel/random/boot_id` and both clocks. Return `error.ClockUnavailable` if identity or either clock is unavailable.
- `collect.memory(bytes: []const u8) Reading(Memory)`, `collect.psi(bytes: []const u8) Reading(u16)`. `collect.readKernel(path: []const u8, buffer: []u8) Reading([]const u8)` maps bounded kernel-file reads into the spec reasons. It consumes a buffer of 8,193 bytes to distinguish a full valid 8,192-byte read from truncation.

- [x] **Add failing config and parser tests.** Include `tume health task 1 canonical config` and `tume health task 1 memory and PSI stay independent` with the following assertions.

```zig
try expect(sameTarget((try parse(a, config_ab)).target, (try parse(a, config_ba)).target));
try expectError(error.InvalidConfig, parse(a, duplicate_key_config));
try expectError(error.InvalidConfig, parse(a, five_services_config));
try expectError(error.InvalidConfig, parse(a, dot_segment_mount_config));
try expectError(error.InvalidConfig, parse(a, leading_dash_unit_config));
try expectError(error.InvalidConfig, parse(a, oversized_4097_byte_config));
try expectEqual(@as(u64, 134217728), memory("MemTotal: 524288 kB\nMemAvailable: 131072 kB\n").value.available_bytes);
try expectEqual(.invalid, memory("MemTotal: 524288 kB\nMemFree: 131072 kB\n").reason);
try expectEqual(.invalid, memory("MemTotal: 18446744073709551615 kB\nMemAvailable: 1 kB\n").reason);
try expectEqual(@as(u16, 101), psi("some avg10=1.005 avg60=0.00 total=4\n").value);
try expectEqual(.invalid, psi("some avg10=nan total=4\n").reason);
```

- [x] **Run red.** `zig test src/tests.zig --test-filter 'tume health task 1'` fails because the new interfaces are undefined.
- [x] **Implement the shared types, strict config parser, `collect.stamp` and bounded kernel reads.** Use checked byte conversion and exact decimal rounding for PSI. Do not reuse the inherited meminfo parser's unchecked conversion or the `MemFree` fallback. Reuse a parser from upstream only where it preserves the T1 missing-data semantics.
- [x] **Run green.** `zig test src/tests.zig --test-filter 'tume health task 1'` exits 0 with both named tests passing.
- [x] **Commit.** `git add src/health/types.zig src/health/config.zig src/health/collect.zig src/tests.zig && git commit -m 'feat: define TUMe health observations and config'`

### Task 2 — Bounded Linux sample assembly

**Files**

- Create `src/health/probe.zig`.
- Modify `src/health/collect.zig` and register the probe tests in `src/tests.zig`.

**Interfaces**

- Consumes `types.Sample`, `types.Target`, `types.Stamp`, `collect.memory`, `collect.psi` and `collect.readKernel`.
- `probe.Request = union(enum) { disk: []const u8, service: []const u8, temperature: u8 }`. `probe.Reply = union(enum) { disk: u16, service: ActiveState, temperature: i32, reason: Reason }`.
- `probe.Runner.run(self: *Runner, req: Request, deadline_boot_ms: u64) Reply` and `probe.Runner.stop(self: *Runner) void`. Use a test transport for child lifecycle and deadline tests.
- `collect.take(allocator: std.mem.Allocator, target: Target, stamp: Stamp, runner: *probe.Runner) !Sample`. The runner is reused across watch ticks. The caller owns returned slices through its allocator.

- [x] **Add failing tests.** Use `tume health task 2 bounded helper lifecycle` with fake boot time and a child that refuses to reap, and `tume health task 2 typed probes` with captured stdout and filesystem counter fixtures.

```zig
try expectEqual(.timeout, runner.run(.{ .disk = "/" }, 1500).reason);
try expectEqual(@as(u64, 250), fake.elapsed_ms);
try expectEqual(.unavailable, runner.run(.{ .service = "gateway.service" }, 1500).reason);
try expectEqual(@as(usize, 1), fake.spawn_count);
try expectEqual(@as(usize, 1), fake.kill_group_count);
try expectEqual(.truncated, fixtureReply(.{ .stdout_bytes = 4096, .stderr_bytes = 1 }).reason);
try expectEqual(.unsupported, serviceReply(1, "LoadState=not-found\nActiveState=inactive\n").reason);
try expectEqual(.unavailable, serviceReply(1, "LoadState=loaded\nActiveState=failed\n").reason);
try expectEqual(.activating, serviceReply(0, "LoadState=loaded\nActiveState=activating\n").service);
try expectEqual(@as(u16, 9000), diskReply(.{ .blocks = 110, .bfree = 20, .bavail = 10, .ext4 = true }).disk);
try expectEqual(.invalid, diskReply(.{ .blocks = 10, .bfree = 10, .bavail = 0, .ext4 = true }).reason);
try expectEqual(@as(i32, -500), thermalReply("-500\n").temperature);
```

  Also assert that `collect.take` returns valid memory and PSI alongside an unavailable disk, stops launching probes at boot ms 1,500, and emits timeout for each configured probe skipped after the collection deadline. Test rejecting a symlink path and a non-ext4 filesystem separately. The test-local helpers above inject the syscall, pipe or parser result into the production branch they exercise.

- [x] **Run red.** `zig test src/tests.zig --test-filter 'tume health task 2'` fails on the missing runner and probe parsing.
- [x] **Implement `Runner.run`, `Runner.stop` and `collect.take`.** Read trusted kernel files in the parent. Run disk descriptor lookup, mount ID verification and stats, the fixed systemctl command and thermal read in a process group with a hard monotonic deadline and bounded output. Treat exited-but-unreaped processes and child pipes separately; only start a new helper once the previous child is reaped and its pipes are closed. Capture boot-clock elapsed time for `Sample.collection_ms` when collection ends. Never block in the parent waiting for a killed helper. Close inherited descriptors in helpers. Use the spec mapping for invalid, unavailable, permission and missing-source outcomes. `Runner.run` uses `timeout` for exhausted deadlines and `unavailable` when an earlier helper remains unreaped. Use the same launch and cleanup path for timeouts, limit breaches and shutdown.
- [x] **Run green.** `zig test src/tests.zig --test-filter 'tume health task 2'` exits 0. On Linux, include model-free helper integration fixtures for timeout, exit and oversize output. They must leave no live test child.
- [x] **Commit.** `git add src/health/collect.zig src/health/probe.zig src/tests.zig && git commit -m 'feat: collect bounded Linux device health samples'`

### Task 3 — Deterministic findings and snapshot command

**Files**

- Create `src/health/findings.zig`, `src/health/report.zig`, `src/health/cli.zig`.
- Modify `src/main.zig` at `printUsage` and `realMain`, and register tests in `src/tests.zig`.

**Interfaces**

- Consumes `config.parse`, `collect.take` and `types.Sample`.
- `findings.RuleId = enum { memory_headroom_low, memory_stalled, disk_capacity_high, service_unavailable }`. `findings.Finding = struct { rule_id: RuleId, subject: []const u8, evidence_key: []const u8, opened_at_unix_ms: i64, input_evaluable: bool }`.
- `findings.State` contains at most seven entries (three device rules and four units), keyed by rule and subject. Each entry holds capped counts and optional open timestamp. `findings.resetStreaks(state: *State) void` preserves open timestamps.
- `findings.instant(allocator: std.mem.Allocator, target: Target, sample: Sample) ![]Finding` and `findings.advance(allocator: std.mem.Allocator, state: *State, target: Target, sample: Sample) ![]Finding`. `advance` expects exactly one eligible sample per call, as enforced by Task 4.
- `report.Report = struct { target: Target, sample: Sample, mode: enum { snapshot, watch }, findings: []const Finding }`. `report.encode(allocator: std.mem.Allocator, value: Report) ![]u8` produces version 1 JSON as defined in the spec.
- `cli.run(allocator: std.mem.Allocator, args: []const []const u8) u8` receives tokens after `health` and returns the process exit code. Use an injected collector and writer for CLI fixtures.

- [x] **Add failing tests.** `tume health task 3 threshold transitions` asserts instantaneous and confirmed results. In the test-local `tick` below, a new stamp is used on each call, the service subject is `gateway.service`, and the three device readings stay normal.

```zig
try expectEqual(@as(usize, 0), (try tick(.failed)).len);
try expectEqual(.service_unavailable, (try tick(.failed))[0].rule_id);
try expect(!(try tick(.activating))[0].input_evaluable);
try expect(!(try tick(.unsupported))[0].input_evaluable);
try expectEqual(@as(usize, 1), (try tick(.active)).len);
try expectEqual(@as(usize, 0), (try tick(.active)).len);
```

  In the same test assert memory 134217727 bytes breaches and 134217728 does not, recovery starts at 167772160, PSI 1000 breaches and 499 recovers, and disk 9000 breaches and 8500 recovers. For each device rule assert two consecutive breaches open and two consecutive recoveries close; a deadband sample resets the streak. `tume health task 3 snapshot contract` asserts these parsed JSON fields using fixture input with a failed unit, 120 ms collection time and no temperature configured.

```zig
try expectEqual(@as(u8, 0), result.exit_code);
try expectEqual(@as(i64, 1), json.schema_version);
try expectEqualStrings("snapshot", json.mode);
try expectEqual(@as(u64, 120), json.collection_ms);
try expectEqualStrings("service:gateway.service", json.findings[0].evidence_key);
try expect(!hasObservation(json, "sensor.temperature"));
try expect(!hasField(json, "streaks"));
try expect(result.stdout.len <= 65536);
```

- [x] **Run red.** `zig test src/tests.zig --test-filter 'tume health task 3'` fails on missing rule or snapshot interfaces.
- [x] **Implement `findings.instant`, `advance` and `resetStreaks`, plus the report and snapshot path.** Keep ordering deterministic by observation key and then finding rule and subject. Treat non-evaluable input as uncertainty on a confirmed finding. Add `health` dispatch before the legacy config load and a Linux target gate. Return exit 2 on invalid usage/config and exit 3 when no valid sample clock or boot identity can be obtained. A snapshot with partial coverage still returns JSON and exit 0.
- [x] **Run green.** Run the T3 filter and `zig build`. Both exit 0. On native Linux, run `nanoclaw-next health snapshot --config` with an absolute path to a valid local JSON config from a temporary directory containing no research config or models. Confirm version 1 JSON, no state created and exit 0. On macOS, confirm exit 2 and the specified Linux-required message instead.
- [x] **Commit.** `git add src/health/findings.zig src/health/report.zig src/health/cli.zig src/main.zig src/tests.zig && git commit -m 'feat: expose deterministic TUMe health snapshots'`

### Task 4 — Watch, durable status and freshness

**Files**

- Create `src/health/state.zig`, `src/health/watch.zig`.
- Modify `src/health/cli.zig` and register tests in `src/tests.zig`.

**Interfaces**

- Consumes `Config`, `Stamp`, `collect.take`, `findings.State`, `findings.advance`, `findings.resetStreaks` and the report schema from Task 3.
- `state.Freshness = enum { fresh, absent, stale, invalid, incompatible, unavailable }`. `state.freshness(saved: Stamp, current: Stamp, same_target: bool) Freshness` classifies a valid version 1 record.
- `state.Store.lock(self: *Store) !void`, `state.Store.load(self: *Store, allocator: std.mem.Allocator, target: Target, now: Stamp) Loaded`, `state.Store.publish(self: *Store, report: Report, confirmed: findings.State) !void`, `state.Store.close(self: *Store) void`. `Loaded = struct { freshness: Freshness, report: ?Report, confirmed: ?findings.State }` has non-null report and confirmed state only when fresh. Import `Report` from `src/health/report.zig`. Bound encoded private reports to 61,440 bytes.
- `watch.cadence(previous_boot_ms: ?u64, current_boot_ms: u64) enum { skip, sample, sample_reset }`. `watch.run(allocator: std.mem.Allocator, config: Config, once: bool) !void`. Use test clock, probe and store seams to exercise one iteration without sleeping.
- `cli.run` now handles snapshot, watch and status. It owns stdout/stderr and maps expected errors to the spec's exit codes.

- [x] **Add failing cadence, state and CLI tests.** In `tume health task 4 cadence across restarts`, assert these boundaries.

```zig
try expectEqual(.sample, cadence(null, 0));
try expectEqual(.skip, cadence(0, 14999));
try expectEqual(.sample, cadence(0, 15000));
try expectEqual(.sample_reset, cadence(0, 30000));
try expectEqual(.fresh, freshness(stamp(0), stamp(44999), true));
try expectEqual(.stale, freshness(stamp(0), stamp(45000), true));
try expectEqual(.invalid, freshness(stamp(200), stamp(199), true));
try expectEqual(.incompatible, freshness(stamp(0), stamp(1), false));
```

  In `tume health task 4 durable local status`, assert a different boot is stale, an unknown schema or changed target is incompatible, and the public report is null in each case. Seed one breach at boot ms 0, restart at 1, and assert zero writes and one persisted breach. Restart at 30000 and assert one breach with no open finding. Simulate a failed pre-rename write and assert `latest.json` is byte-identical. Simulate a failed directory sync after rename and assert the one-shot returns 3, while the visible record is complete. Assert a symlink lock or state file is rejected, a second writer cannot acquire the lock, and a valid fresh report contains no public streaks.

- [x] **Run red.** `zig test src/tests.zig --test-filter 'tume health task 4'` fails on the missing watch or store interfaces.
- [x] **Implement `Store`, `watch.cadence`, `watch.run` and the remaining CLI paths.** Lock writers only. Validate and cap every loaded field before resuming. Encode a full bounded record, synchronize and atomically replace from a fixed same-directory temporary name. Use only owner-controlled directory descriptors. Keep streaks in memory through an unsuccessful publish and throttle failure reporting. On signals stop the probe runner and exit the loop. Status readers classify the latest record without taking the writer lock. Missing boot identity or clock data fails explicitly instead of reusing a timestamp.
- [x] **Run green.** `zig test src/tests.zig --test-filter 'tume health task 4'` and `zig build test` exit 0. On Linux, run watch `--once` and status against a private local ext4 fixture directory, verify status freshness and change one configured unit to verify exit 3 with `freshness: incompatible`.
- [x] **Commit.** `git add src/health/state.zig src/health/watch.zig src/health/cli.zig src/tests.zig && git commit -m 'feat: persist fresh local TUMe health and findings'`

### Task 5 — Unprivileged deployment and pilot evidence

**Files**

- Create `deploy/systemd/tume-health.service`, `deploy/systemd/health.example.json`, `docs/operations/linux-health.md`.
- Create `docs/evidence/T1-linux-health.md` with authorized pilot results or a pending status and the precise remaining validation.

**Interfaces**

- Consumes the released CLI and version 1 report. Produces a private systemd watcher and an operator-verifiable install, status, stop and removal flow.

- [x] **Define the failing release smoke check on a designated Linux host.** The check expects an installable unit with `User=tume-health`, `StateDirectory=tume`, `StateDirectoryMode=0700` and absolute `ExecStart=/usr/local/bin/nanoclaw-next health watch --config /etc/tume/health.json`. Verify the unit and use the service account for the status CLI. The absent deployment artifacts cause the first check to fail.
- [x] **Add the unit, config and operator guide.** Use a dedicated static service account to preserve direct, owner-only access to `/var/lib/tume`. Set `NoNewPrivileges=yes`, `UMask=0077`, `MemoryAccounting=yes`, `CPUAccounting=yes`, `KillMode=control-group`, `TasksMax=8`, `TimeoutStopSec=3s`, `Restart=on-failure`, `RestartSec=5s`, `StartLimitIntervalSec=60s` and `StartLimitBurst=3`. The example specifies mount `/`, no services and no thermal sensor. Document the exact ownership and install paths, enabling the unit, querying as the service account, editing config and restarting, and optional deletion of state on uninstall. Describe required system-bus permissions and the supported disk filesystem.
- [ ] **Run the release smoke check.** On the authorized x86_64 host with the binary installed at its documented path, `systemd-analyze verify deploy/systemd/tume-health.service` exits 0. The installed unit runs unprivileged, status returns exit 0 and schema version 1, no repair/listening service appears, and `systemctl stop tume-health.service` leaves no child in the unit cgroup. Record the host and outcomes. Use only dedicated pilot or test hosts.
- [x] **Record pilot status and evidence.** With explicit device/workload authorization, run the paired trial and disposable fault check in the spec. Capture total cgroup memory, CPU, persistent and journal bytes, timing, broker metrics and incorrect/missed findings. Report comparator settings and results under the same load. Include a row with measured value and pass/fail for each gate. Until these trials are authorized and run, mark T1 pilot validation pending. Keep raw credentials, ignored state and model files out of Git.
- [x] **Commit.** `git add deploy/systemd/tume-health.service deploy/systemd/health.example.json docs/operations/linux-health.md docs/evidence/T1-linux-health.md && git commit -m 'docs: package TUMe health and record pilot readiness'`

## Handoff

The portable fixture suite passed on macOS and both Linux targets cross-compiled. The arm64 Ubuntu VM passed native fixtures, live watch/status and installed systemd checks. The x86_64 native smoke and the separate physical-device gates remain pending. See the [T1 evidence record](../../evidence/T1-linux-health.md).
