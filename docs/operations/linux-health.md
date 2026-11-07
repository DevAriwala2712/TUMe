# Run TUMe device health on Linux

The T1 implementation has a one-shot snapshot, a watcher and a local status reader. It collects host memory, memory and CPU stall pressure, local disk usage, selected systemd service state and an optional thermal reading. Linux runtime and physical-device validation are tracked in the [T1 evidence record](../evidence/T1-linux-health.md).

## Take a snapshot

Use Zig 0.15.2 on Linux arm64 or x86_64. The disk probe requires a local ext4 directory. Check the configured mount with `findmnt -no FSTYPE --target /`. Replace `/` in the example config if the root filesystem uses a different type.

```sh
zig build -Doptimize=ReleaseSmall
./zig-out/bin/nanoclaw-next health snapshot --config deploy/systemd/health.example.json
```

The snapshot prints version 1 JSON and writes no state. Add up to four exact systemd service unit names to `services` and set `thermal_zone` to a known zone number to enable temperature. Service observations use a fixed, read-only `systemctl show` request. The account needs permission to query the local system bus and read the chosen thermal source. Missing or inaccessible sources carry a reason in the report.

The four finding rules cover memory headroom below 128 MiB, memory stalls at or above 10% over the PSI 10-second window, disk usage at or above 90%, and a selected service that is failed or inactive. The watcher opens a finding after two consecutive breaches and clears it after two recovery observations. See the [design](../superpowers/specs/2026-11-07-linux-health-design.md) for recovery thresholds, the JSON fields and state freshness.

## Install the watcher

On a designated Linux test host, create a dedicated local account and group once. If they already exist, verify that they belong to this service before using them.

```sh
sudo groupadd --system tume-health
sudo useradd --system --gid tume-health --no-create-home \
  --home-dir /var/lib/tume --shell /usr/sbin/nologin tume-health
sudo install -m 0755 zig-out/bin/nanoclaw-next /usr/local/bin/nanoclaw-next
sudo install -d -m 0755 /etc/tume
sudo install -m 0640 -o root -g tume-health deploy/systemd/health.example.json /etc/tume/health.json
sudo install -m 0644 deploy/systemd/tume-health.service /etc/systemd/system/tume-health.service
sudo systemd-analyze verify /etc/systemd/system/tume-health.service
sudo systemctl daemon-reload
sudo systemctl enable --now tume-health.service
```

systemd creates `/var/lib/tume` with mode `0700` for the service account. The service restricts socket creation to Unix sockets so it can query the local system bus. The state directory must be on local ext4. For manual tests, create a private local ext4 state directory owned by the running account and set `state_dir` accordingly. Use `health watch --config PATH --once` to publish once. A second one-shot within 15 seconds returns without advancing the watcher.

Inspect status as the owner of the state:

```sh
sudo -u tume-health /usr/local/bin/nanoclaw-next health status --config /etc/tume/health.json
```

Exit 0 means the report is fresh, including when it contains findings or unavailable observations. Exit 2 indicates invalid configuration, usage or platform. Exit 3 means status is unavailable or stale, or a command could not complete. In status JSON, inspect `freshness` and each observation's `reason`. A stale report or a report for a different configured target has a null public report. A fresh report can still have incomplete coverage.

Edit `/etc/tume/health.json` with administrative access and run `sudo systemctl restart tume-health.service` to apply it. If a watcher cannot publish, inspect `sudo journalctl -u tume-health.service` and the free space and ownership of the state directory.

## Stop or remove

```sh
sudo systemctl disable --now tume-health.service
sudo rm /etc/systemd/system/tume-health.service
sudo systemctl daemon-reload
```

Keep the configuration and state if you plan to reinstall. To remove them, delete `/etc/tume/health.json` and `/var/lib/tume` after stopping the unit. Remove the shared `nanoclaw-next` binary only if you no longer use the research CLI. The dedicated account and group can be removed once their files are no longer needed.
