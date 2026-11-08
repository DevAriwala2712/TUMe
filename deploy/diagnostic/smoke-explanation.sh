#!/usr/bin/env bash
set -euo pipefail
# This test installs a transient failing unit and temporary cgroups.
if [[ $(id -u) != 0 || $# != 2 || $1 != --disposable-vm ]]; then
    printf '%s\n' 'Usage as root in a disposable Ubuntu VM: bash smoke-explanation.sh --disposable-vm /path/to/nanoclaw-next' >&2
    exit 2
fi
binary=$(realpath "$2")
test -x "$binary"
test "$(uname -s)" = Linux
test -d /run/systemd/system
test "$(findmnt -no FSTYPE --target /var/tmp)" = ext4
id ubuntu >/dev/null
user=ubuntu
fixture="tume-explanation-fixture-$$.service"
unit="/run/systemd/system/$fixture"
watch_unit="tume-explanation-watch-$$.service"
work=$(mktemp -d /var/tmp/tume-explanation.XXXXXX)
scope="/sys/fs/cgroup/tume-explanation-smoke-$$"
broker="$scope/broker"
job="$scope/job"
cleanup() {
    systemctl stop "$watch_unit" >/dev/null 2>&1 || true
    if [[ -d "$job" ]]; then
        echo 1 > "$job/cgroup.kill"
        rmdir "$job" "$broker" "$scope"
    fi
    systemctl reset-failed "$fixture" || true
    rm -f -- "$unit"
    systemctl daemon-reload
    rm -rf -- "$work"
}
trap cleanup EXIT
chmod 0755 "$work"
install -d -m 0700 -o "$user" -g "$user" "$work/state"
cat > "$unit" <<'UNIT'
[Service]
Type=oneshot
ExecStart=/usr/bin/false
UNIT
systemctl daemon-reload
if systemctl start "$fixture" >/dev/null 2>&1; then
    exit 1
fi
test "$(systemctl show -p ActiveState --value "$fixture")" = failed
cat > "$work/health.json" <<JSON
{"mount":"/","state_dir":"$work/state","services":["$fixture"],"thermal_zone":null}
JSON
sudo -u "$user" "$binary" health watch --config "$work/health.json" --once
sleep 15
sudo -u "$user" "$binary" health watch --config "$work/health.json" --once
sudo -u "$user" "$binary" health status --config "$work/health.json" > "$work/status.json"
python3 -I - "$work/status.json" "service:$fixture" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    v = json.load(stream)
assert v["freshness"] == "fresh"
assert any(x["evidence_key"] == sys.argv[2] for x in v["report"]["findings"])
PY

mkdir "$scope"
echo '+cpu +memory +pids' > "$scope/cgroup.subtree_control"
mkdir "$broker" "$job"
echo 67108864 > "$job/memory.max"
echo 0 > "$job/memory.swap.max"
echo '20000 100000' > "$job/cpu.max"
echo 8 > "$job/pids.max"
chown "$user" "$scope/cgroup.procs" "$job/cgroup.procs" "$job/cgroup.kill"
cat > "$work/backend" <<'BACKEND'
#!/bin/sh
set -eu
[ "$1" = --max-tokens ] && [ "$2" = 64 ] && [ "$3" = --request-json ]
id=${4#*\"id\":\"}
id=${id%%\"*}
[ "${#id}" = 64 ]
case "$0" in
    *invalid) id=invented ;;
    *hanging) exec /bin/sleep 25 ;;
esac
printf '{"schema_version":1,"cause":"unit_failed","citation":"%s"}\n' "$id"
BACKEND
chmod 0755 "$work/backend"
cp -p "$work/backend" "$work/backend-invalid"
cp -p "$work/backend" "$work/backend-hanging"
for variant in valid invalid hanging; do
    suffix=''
    timeout=3000
    case "$variant" in
        invalid) suffix=-invalid ;;
        hanging)
            suffix=-hanging
            timeout=17000
            systemd-run --quiet --unit="$watch_unit" --uid="$user" --gid="$user" \
                -- "$binary" health watch --config "$work/health.json"
            ;;
    esac
    cat > "$work/policy.json" <<JSON
{"schema_version":1,"backend":"$work/backend$suffix","job_cgroup":"$job",
 "measured_peak_bytes":4194304,"reserve_bytes":4194304,"timeout_ms":$timeout,
 "max_output_bytes":4096,"max_tokens":64}
JSON
    rc=0
    sh -c '
        echo "$$" > "$1/cgroup.procs"
        shift
        exec setpriv --reuid ubuntu --regid "$(id -g ubuntu)" --clear-groups --no-new-privs -- "$@"
    ' sh "$broker" "$binary" health explain --config "$work/health.json" --policy "$work/policy.json" \
        --finding "service:$fixture" > "$work/$variant.json" || rc=$?
    if [[ $variant == valid ]]; then test "$rc" = 0; else test "$rc" = 3; fi
    grep -qx 'populated 0' "$job/cgroup.events"
done
sudo -u "$user" "$binary" health status --config "$work/health.json" > "$work/status-after.json"
python3 -I - "$work" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
valid = json.loads((root / "valid.json").read_text())
invalid = json.loads((root / "invalid.json").read_text())
assert valid["outcome"] == "explained" and valid["possible_cause"] == "unit_failed", valid
assert valid["request"]["evidence"]["value"] == {"active_state": "failed"}, valid
assert valid["request"]["evidence"]["id"] == valid["next_check"]["evidence_id"], valid
assert invalid["outcome"] == "inconclusive" and invalid["reason"] == "unsupported_proposal", invalid
hanging = json.loads((root / "hanging.json").read_text())
assert hanging["outcome"] == "inconclusive" and hanging["reason"] == "timed_out", hanging
before = json.loads((root / "status.json").read_text())["report"]["sampled_at_boot_ms"]
after = json.loads((root / "status-after.json").read_text())["report"]["sampled_at_boot_ms"]
assert after - before >= 15000, (before, after)
print("T2.3 accepted the grounded reply, rejected the forged citation, and published health during a timed-out job")
PY
