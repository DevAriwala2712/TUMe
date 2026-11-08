# Local incident history

The Linux watcher can retain finding transitions and offer next checks offline. History is opt-in and requires the same owner-only ext4 state directory as `health status`. Add the history object to an existing health configuration.

```json
{
  "mount": "/",
  "services": ["gateway.service"],
  "state_dir": "/var/lib/tume",
  "history": {
    "enabled": true,
    "journal_metadata": false,
    "workload_release": "1.2.3"
  }
}
```

The release label is optional and records the configured workload version. A change adds context to the timeline. The continuous watcher publishes current health first, then delegates history work to a separate helper. Snapshots and `watch --once` leave history alone.

Run these commands as the owner of the configured state directory.

```sh
nanoclaw-next health incidents --config /etc/tume/health.json
nanoclaw-next health incidents --config /etc/tume/health.json --id INCIDENT_ID
```

The list shows up to 20 retained incidents in descending order of their most recent evidence. Detail shows up to 16 events and evidence-linked next checks. A fresh status report indicates whether the finding is currently present under the configured target. The incident's own status describes its retained episode. Following a watcher restart or observation gap, a separately identified episode can link back to a previous open episode. Recovery appears only after T1 confirms it with valid readings.

History is limited to 24 hours, 128 events and 128 KiB. An incident is partial when its opening evidence has expired or been evicted. A stopped watcher can still leave readable history, and reads apply time retention. History status reports empty, invalid, incompatible, or unavailable data separately from T1 freshness. Exit 0 indicates a valid response. Exit 2 indicates invalid usage, config, or a disabled feature. Exit 3 includes an expired or unknown incident, invalid history, or unavailable state. To preserve invalid data for inspection, stop the watcher and archive the private history file before starting with an empty history. The watcher preserves incompatible history files.

## Optional journal metadata

To include service journal metadata, enable `history.journal_metadata` in the watcher configuration before collecting the opening and invoke the detail command with `--journal`.

```sh
nanoclaw-next health incidents --config /etc/tume/health.json --id INCIDENT_ID --journal
```

The invoking identity needs both history ownership and read access to the system journal. The query uses the recorded boot, the still-configured unit, and a window from five minutes before opening to one minute after it. Visible matches have limited coverage. Empty results can also indicate inaccessible entries. The output carries metadata and citation IDs. Journal messages, cursors, and process arguments stay out of incident reports and persistent history. [systemd journal fields](https://www.freedesktop.org/software/systemd/man/latest/systemd.journal-fields.html) · [journalctl](https://www.freedesktop.org/software/systemd/man/latest/journalctl.html)

The helper has a 250 ms deadline. In the packaged unit, systemd manages the watcher and its helpers together. Apply equivalent process limits when running a continuous watcher manually.

## Validation status

Fixture tests cover lifecycle transitions for the four T1 rules, restart links, deterministic evidence IDs, pre- and post-rename failure, malformed history, and a journal projection containing seeded credentials. An ARM64 Ubuntu 24.04 VM smoke test used a disposable failed service to verify opening, metadata-only journal lookup, and a restart-linked episode with a recorded gap. Physical-device resource overhead and the comparative operator study remain release gates. See the [design and acceptance criteria](../superpowers/specs/2026-11-07-incident-timeline-design.md).
