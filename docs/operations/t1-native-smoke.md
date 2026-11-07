# T1 native Linux smoke test

Use a designated x86_64 Linux test host with systemd, cgroup v2, Zig 0.15.2 and Python 3. Run from the TUMe checkout. Record the commit, OS, kernel, systemd and Zig versions, filesystem type, and each outcome in the [T1 evidence record](../evidence/T1-linux-health.md). These checks exercise the actual Linux CLI and installed unit. The [Pi pilot protocol](../superpowers/specs/2026-11-07-linux-health-design.md) separately measures resource use and fault behavior.

## Native CLI and fixture checks

Run this block as an ordinary user. It uses an isolated temporary directory on ext4 and checks the status contract through the real binary. Set `TUME_SMOKE_PARENT` to a writable local ext4 directory if `/var/tmp` is on another filesystem.

```bash
bash <<'SMOKE'
set -euo pipefail
test "$(uname -s)" = Linux
test "$(uname -m)" = x86_64
test "$(id -u)" -ne 0
test "$(zig version)" = 0.15.2
test -d /run/systemd/system
test -f /sys/fs/cgroup/cgroup.controllers
parent=$(realpath -e -- "${TUME_SMOKE_PARENT:-/var/tmp}")
test "$(findmnt -no FSTYPE --target "$parent")" = ext4

zig build test --summary all
zig build -Doptimize=ReleaseSmall
binary=$(realpath -e -- zig-out/bin/nanoclaw-next)
work=$(mktemp -d "$parent/tume-smoke.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
umask 077
mkdir -m 0700 -- "$work/state"
cd "$work"

python3 -I - "$work" <<'PY'
import json
import sys
from pathlib import Path

work = Path(sys.argv[1])
config = {"mount": str(work), "state_dir": str(work / "state"),
          "services": ["systemd-journald.service"], "thermal_zone": None}
(work / "health.json").write_text(json.dumps(config))
config["services"] = []
(work / "changed.json").write_text(json.dumps(config))
PY

expect_unavailable() {
    local config=$1 output=$2 result=0
    "$binary" health status --config "$config" > "$output" || result=$?
    test "$result" -eq 3
}

"$binary" health snapshot --config health.json > snapshot.json
test -z "$(find state -mindepth 1 -print)"
expect_unavailable health.json absent.json
"$binary" health watch --config health.json --once
"$binary" health status --config health.json > fresh.json
expect_unavailable changed.json incompatible.json
test "$(stat -c '%a:%u' state/latest.json)" = "600:$(id -u)"

python3 -I - <<'PY'
import json
from pathlib import Path

def read(name):
    return json.loads(Path(name).read_text())

snapshot = read("snapshot.json")
assert snapshot["schema_version"] == 1 and snapshot["mode"] == "snapshot"
assert read("absent.json") == {
    "schema_version": 1, "freshness": "absent", "report": None,
}
fresh = read("fresh.json")
assert fresh["schema_version"] == 1 and fresh["freshness"] == "fresh"
assert fresh["report"]["mode"] == "watch" and "streaks" not in fresh["report"]
assert read("incompatible.json") == {
    "schema_version": 1, "freshness": "incompatible", "report": None,
}
for report in (snapshot, fresh["report"]):
    observations = {row["key"]: row for row in report["observations"]}
    assert observations["disk.mount"]["value"] is not None
    assert observations["host.memory"]["value"] is not None
    assert observations["service:systemd-journald.service"]["value"] == {
        "active_state": "active",
    }
    assert all((row["value"] is None) != (row["reason"] is None)
               for row in observations.values())
PY
printf 'T1 native CLI smoke passed\n'
SMOKE
```

## Installed unit smoke

On the designated host, [install the unit and example configuration](linux-health.md#install-the-watcher). Stop that test instance before running the following block. The block starts and stops the unit and checks that the report was sampled after the start, the process used the dedicated account, and the service cgroup has no remaining tasks after stopping.

```bash
bash <<'SMOKE'
set -euo pipefail
unit=tume-health.service
test -f /sys/fs/cgroup/cgroup.controllers
sudo systemd-analyze verify /etc/systemd/system/"$unit"
if systemctl is-active --quiet "$unit"; then
    printf 'Stop the designated test instance before running this check.\n' >&2
    exit 1
fi

started=$(python3 -I -c 'import time; print(time.clock_gettime_ns(time.CLOCK_BOOTTIME) // 1_000_000)')
sudo systemctl start "$unit"
trap 'sudo systemctl stop "$unit"' EXIT
fresh=0
for attempt in $(seq 1 20); do
    if report=$(sudo -u tume-health /usr/local/bin/nanoclaw-next health status --config /etc/tume/health.json) &&
       printf '%s\n' "$report" | python3 -I -c '
import json, sys
v = json.load(sys.stdin)
ok = (v["schema_version"] == 1 and v["freshness"] == "fresh"
      and v["report"]["sampled_at_boot_ms"] >= int(sys.argv[1]))
raise SystemExit(0 if ok else 1)
' "$started"; then
        fresh=1
        break
    fi
    sleep 1
done
test "$fresh" -eq 1
pid=$(systemctl show --value --property=MainPID "$unit")
test "$pid" -gt 0
test "$(ps -o euid= -p "$pid" | tr -d '[:space:]')" = "$(id -u tume-health)"
cgroup=$(systemctl show --value --property=ControlGroup "$unit")
test -n "$cgroup"

sudo systemctl stop "$unit"
trap - EXIT
test "$(systemctl show --value --property=MainPID "$unit")" -eq 0
events="/sys/fs/cgroup${cgroup}/cgroup.events"
if sudo test -e "$events"; then
    sudo grep -qx 'populated 0' "$events"
fi
printf 'T1 systemd start, fresh status, user and stop checks passed\n'
SMOKE
```

Record actual outcomes. If a check fails, save the failing command and relevant sanitized output. Leave the corresponding acceptance gate pending until it passes on the designated host.
