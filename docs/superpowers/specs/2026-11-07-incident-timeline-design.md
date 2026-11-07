# TUMe T2.1 incident timeline and next checks

**Draft for review · 2026-11-07.** T1 Linux deployment and the physical Pi pilot are pending. This design defines the proposed first diagnosis deliverable. [Roadmap](../../PLAN.md) · [T1 evidence](../../evidence/T1-linux-health.md)

## Operator outcome

An operator arrives after a gateway fault and can reconstruct when TUMe observed it, which measurements supported it, whether it recovered, and where observation stopped. The same operator can get specific next checks while offline, without installing a model or granting repair permissions. A current report, a historical observation and a gap in evidence have distinct meanings.

A service episode can show a restart boundary and link to the later observation.

```text
gateway.service · service_unavailable · last observed open
10:14:15   confirmed opening · service=failed · evidence obs_…
10:15:00   observation gap · watcher restarted
Related episode   observed open again at 10:15:30 · incident 75ae…
Journal metadata   2 entries matched · limited coverage
Next check         Inspect the unit's current state and its dependencies.
```

T1's snapshot, watch and status commands retain their version 1 public report. T2.1 adds a local history read path and a deterministic guide to the four existing rules. T2.2 admission control, T2.3 model explanations and T3 procedures have separate designs.

## Approaches

| Approach | Trade-off |
|---|---|
| **Bounded TUMe history with journal lookup on request (proposed)** | Retain the observations TUMe actually saw even after journal rotation. Keep journal access and parsing outside steady-state monitoring. Journal evidence can disappear before an operator requests it, so expose its coverage separately. |
| Journal as the sole timeline store | Reuses retention and indexing. Gaps, host findings and private evidence would then depend on the host's journal configuration and read permissions. |
| Continuous ingestion into a local database | Can preserve more context and support indexed queries. Introduces continuous input handling, broader access and a larger deployment and I/O budget. Revisit after the pilot measures a need for retained journal context. |

Use Zig 0.15.2, Linux systemd and local ext4. Use the standard library and the host's journal CLI. TUMe owns the finding lifecycle and the evidence references. The host journal remains the source for optional service metadata.

## Operator and compatibility contract

- Keep existing `nanoclaw-next` and research configuration identifiers. Preserve T1 JSON and exit behavior, including the private `latest.json` format. No migration is needed for a T1 installation.
- Add an optional `history` object to the existing health configuration with `enabled` (boolean, default false), `journal_metadata` (boolean, default false), and optional `workload_release` (canonical numeric `major.minor.patch`, each component 0–65535). Continue rejecting duplicate and unknown fields. Reject journal metadata or a release label when history is disabled. The owner supplies the workload release label. An absent label means unknown.
- `nanoclaw-next health incidents --config PATH` lists the latest 20 retained incidents, newest first, and reports whether older results were omitted. `--id ID` returns a single incident, up to 16 of its most recent events, their observation references, and next checks. Each detail covers one continuous episode. A boundary gap can link to a separately identified re-observation of the same rule and subject under the same configured target. `--journal` requires both `--id` and `history.journal_metadata=true`.
- The history reader needs the same state ownership as T1 status. The watcher needs no added journal group or capability. The invoking identity needs both owner-only history access and journal read access. Running the command as the dedicated service user does not transfer the operator’s journal permissions. The default service account may return no visible metadata. Installations with narrower access can still use history and next checks.
- Return JSON with `schema_version=1` for the new command. Include `kind` (`list` or `detail`), `history_status`, `latest_status_freshness`, and `truncated`, plus either the list or detail. Use history status values of `available`, `empty`, `invalid`, `incompatible`, or `unavailable`. History may be readable when current T1 status is stale. Use exit 0 for a valid response including empty history or missing journal coverage, 2 for usage or disabled features, and 3 for an unknown/expired incident, invalid history or unavailable state. The new response is limited to 65,536 bytes, including newline. On a size limit, omit oldest whole records and report truncation.

## What the timeline records

Capture a compact delta only after an eligible T1 watch sample publishes successfully. Snapshots and all `watch --once` calls keep their T1 behavior and never write history. Only continuous watch produces history. Reuse T1's rule decisions and evidence types. Add an explicit event for an observed recovery so that disappearing from a report never becomes a recovery by itself.

| Event | Meaning |
|---|---|
| `opened` | The T1 rule transitioned to open after confirmed breaches. Include the triggering observation. |
| `resolved` | The same tracked episode reached T1's confirmed recovery threshold with valid readings. Include the recovery observation. |
| `observed_open` | The current report contains an open finding when the timeline has no continuous baseline. Attach the first evidence actually observed by this timeline. |
| `coverage_lost`, `coverage_resumed` | A tracked finding's input became unevaluable or evaluable. Include its missing-data reason or transitional unit state where relevant. |
| `gap` | An observation interval is incomplete because of a restart, missed tick, failed publication or history write. The reason identifies the boundary. |
| `context_changed` | A new boot, configured target, agent build version or workload release was observed. Record the specific field and known old and new values. A version change is context, with no claim that it caused a fault. |

Emit at most one finding event per rule and subject per eligible sample. Give an opening or recovery precedence over a coverage change at the same sample. A single context event may contain several changed fields.

Every event has a stable `event_id`, append order, boot ID, T1 boot-relative and display timestamps, and the journal monotonic timestamp when available. A finding event also carries `incident_id`, rule ID, subject and at most the triggering observation plus one supporting observation. Use a source field with `tume_sample`, `watcher`, or `operator_config` and a typed reason for events without a measurement. List and detail label an episode `last_observed_open` if its latest retained evidence shows it open, or `resolved` if a matching recovery is retained. Show the current T1 observation separately as `present` or `absent` for a fresh report under the same target, and `unknown` when status or scope cannot be verified. A current finding can recur after a gap, so its presence alone does not link it to an older episode.

Use canonical, ordered tuples and the first 128 bits of SHA-256 encoded as lowercase hex. Namespace IDs by purpose. Derive the incident ID from the boot ID, canonical T1 target digest, segment start boot time, rule ID, subject and first observed boot time. Derive event IDs from the incident or context scope, sample boot time and event kind. Derive observation IDs from event ID and observation key. IDs remain stable across retries and use the same stored values after restart. Keep separate ordering and identity fields so wall-clock changes cannot reorder events.

Start a new segment after restart, reboot, target change, or a gap of 30 seconds or more between eligible observations. A failed T1 publication, skipped history delta, failed history write or uncertain durability also breaks history continuity. Record a gap on the next successful history write. Record an already-open finding as `observed_open` in the new segment and preserve the old episode as historical evidence. Link it to the most recent previously open episode only when the target digest, rule and subject agree and that episode is still retained. The link says the finding was observed again after a gap. It does not assert uninterrupted failure. A build or workload release change is a context marker. It never closes a finding on its own. Read the agent version from compile-time release metadata and the workload release from the approved config. The history path makes no package manager or network calls.

## Retention, isolation and recovery

- Keep at most **24 hours, 128 events and 128 KiB** of encoded history, whichever removes records first. The temporary file adds at most another 128 KiB. Evict oldest whole events. Keep the newest retained evidence readable after eviction, mark an incident whose opening evidence aged out as partial, and expose truncation. Refs point only to records included in the response or explicitly marked unavailable.
- Use `CLOCK_BOOTTIME` to age events within a boot. For a previous boot, use wall-clock age only when the observed ordering is consistent and the age is nonnegative and below 24 hours. Discard older-boot records if the wall/boot elapsed-time difference shifts by more than five minutes within the current boot, or if chronology is uncertain. Prune on an event write or on the first eligible tick after records expire. History reads apply retention even while the watcher is stopped. Physical deletion occurs when the enabled writer next succeeds.
- Store a versioned private `history.json` using the owner-only directory rules, file and directory sync, and atomic rename already used by T1. Read a complete old or new file. Preserve unknown future versions and report incompatible history. A corrupt record is explicitly invalid; an operator can archive or remove it before starting a new history. There is no automatic rewrite of invalid or unknown data.
- Publish T1 status first. A single history helper can consume a bounded delta of at most 16 events. The child closes the inherited T1 writer-lock descriptor and all other unrelated descriptors before filesystem operations, so a history stall cannot prevent T1 from restarting. It owns a separate nonblocking history lock, writes only history files and rejects a write based on a stale generation before replacement. Supervise it with a 250 ms deadline and nonblocking reap. Keep one pending delta at most. On contention, timeout, quota exhaustion or failed sync, drop the delta, record a pending gap and continue T1. Allow one history helper per watcher invocation. Its separate lock serializes commits. Across installed service restarts, rely on control-group termination and the existing task cap, including children stuck before obtaining the history lock. A manually supervised continuous watcher needs equivalent process limits. Clock and memory accounting include all helpers. Do not wait for blocked history I/O in the watcher.
- A failure after rename may expose a complete history version. Use deterministic event IDs to make a replay safe and report uncertain coverage on the next write. No durability guarantee spans the two files. When latest status and history disagree, display their separate times and coverage. History failure never changes the T1 finding or freshness contract.

## Optional journal metadata

Use a bounded, on-demand query for one selected `service_unavailable` episode. Match its recorded boot and unit. The unit must still be present in the current health configuration. For a removed unit, keep historical TUMe evidence and report the journal query as out of scope. Look up only the five minutes before and one minute after its opening or first observed-open event, clipped to available data. The journal's monotonic timestamp uses `CLOCK_MONOTONIC`, while T1 scheduling uses `CLOCK_BOOTTIME`. Capture a separate monotonic anchor at the T1 sample. Compare only timestamps from the same boot and clock. Return unavailable coverage if the anchor is missing. [systemd journal fields](https://github.com/systemd/systemd/blob/v255/man/systemd.journal-fields.xml) · [Linux clocks](https://man7.org/linux/man-pages/man2/clock_gettime.2.html)

Run a fixed `/usr/bin/journalctl` argv with the system journal, no pager, JSON output, a boot and unit filter, and at most 33 candidates from a bounded window. Require a usable anchor wall time to set `--since` and `--until` search hints, and enforce the actual boot and monotonic window on each returned row. A missing or ambiguous wall time leaves journal coverage unavailable or limited. Mark the result limited if timestamps disagree, the journal only covers part of the window, or the candidate limit is hit. A successful empty response reports that no matching rows were visible to the caller. Use the same 250 ms process deadline and a combined stdout/stderr cap of 16 KiB. Select newest first, then emit up to 32 matching, deduplicated metadata rows ordered by monotonic time and citation ID. [journalctl options and JSON format](https://github.com/systemd/systemd/blob/v255/man/journalctl.xml)

Project each row to a typed record with source `system_journal`, boot ID, unit, journal monotonic time, display time, and one of `manager_event` or `unit_log_event`. Accept unit process attribution from the trusted `_SYSTEMD_UNIT` field. Accept manager attribution only for the matching `UNIT` from PID 1 in the selected boot. Treat timestamps, row structure and all content as untrusted at the parser boundary. A duplicate cursor can be recognized using its bounded hash. Raw cursors and raw journal fields never reach the response. Use coverage states `limited`, `empty_or_inaccessible`, `out_of_scope`, `unavailable`, `timeout`, `invalid`, and `truncated`. A result with visible rows is limited because the query cannot prove journal completeness. [Trusted and application-supplied journal fields](https://github.com/systemd/systemd/blob/v255/man/systemd.journal-fields.xml)

Do not request `MESSAGE`, command lines, environment values or application payloads. Drop them if present in malformed or hostile fixtures. Do not store journal rows or echo stderr. Keep the normalized metadata in memory for the requested response and derive a citation ID from the validated scope and cursor digest. This policy removes the fields that could carry credentials before storage or display. Journal rows never affect T1 rules or grant authority.

## Deterministic next checks

Return stable check codes, operator-facing text, and references to the evidence that triggered the suggestion. If the current source is unknown, lead with the missing coverage and mark the recommendation as based on historical evidence. Each finding grounds a next check and leaves the root cause open.

| T1 finding | Ordered checks |
|---|---|
| `memory_headroom_low` | `inspect_memory_consumers` to review the protected workload and largest memory users. `compare_memory_and_stalls` to compare available memory with memory PSI when it was observed. |
| `memory_stalled` | `review_pressure_window` to inspect whether memory stalls coincided with the workload symptom. `compare_headroom` to inspect the latest available-memory reading and note missing coverage. |
| `disk_capacity_high` | `inspect_mount_usage` to identify growth on the configured mount. `review_retention_and_writes` to inspect log, data and backup retention before making changes. |
| `service_unavailable` | `verify_unit_state` to check the unit and its dependencies. `review_service_events` to inspect its timeline and any visible journal metadata. |

Checks contain descriptions and evidence IDs. They carry no command templates, write permissions or procedure dispatch.

## Acceptance before T2.1 release

| Gate | Required evidence |
|---|---|
| Correct history | Replay all four T1 rules through open, recovery and unevaluable input. Include a reboot, target and version changes, a restart with stale T1 state, a missed tick, and a failure before and after history rename. Assert exact event kinds, stable IDs, explicit gaps, and zero fabricated resolutions. |
| Time and bounds | Exercise duplicate, reordered, malformed, future-dated and oversized records. Verify retention limits, deterministic truncation, separate clocks after suspend, and reports with fewer than five minutes of visible journal data. |
| Data handling | Seed credentials, bearer tokens, shell fragments and control characters in journal fields. Assert that only the allowed metadata survives, no secret reaches a file, CLI output or error, and a hostile row cannot affect a finding. |
| Operator usefulness | Use at least 12 labeled fixture incidents across the four rules and incomplete-evidence cases. Compare incident ordering, correct next check and false certainty against T1 status alone. Require the expected leading check for every labeled case and explicit uncertainty for each coverage gap. |
| Resource and fault isolation | Verify that disabled history starts no helper and writes no state. Exercise a busy journal, a hung history helper and full storage with model-free fakes. On the authorized Pi, measure idle watcher and active history lookup, including every process, I/O, journal and disk bytes. Keep the T1 workload and whole-service gates, and report separate history overhead and query latency. |

The first implementation slice should exercise timeline storage and deterministic next checks with fixtures, then add the optional journal path. Review the proposed caps, on-demand metadata approach and operator workflow before turning this draft into an implementation plan.
