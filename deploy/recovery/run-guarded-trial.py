#!/usr/bin/env python3
"""Exercise the opt-in T3.3 policy after the manual trial on the same authorized VM."""

import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import runpy
import select
import subprocess
import tempfile
import time


ASSETS = Path(__file__).resolve().parent
TRIAL = runpy.run_path(str(ASSETS / "run-disposable-trial.py"))
run = TRIAL["run"]
install = TRIAL["install"]
expect_result = TRIAL["expect_result"]
service = TRIAL["service"]
wait_for = TRIAL["wait_for"]
STATE, UNIT, HELPER = (TRIAL[name] for name in ("STATE", "UNIT", "HELPER"))
AUTO = "/usr/local/libexec/tume-recovery-automatic"
AUTO_SERVICE = "tume-recovery-automatic.service"
AUTO_TIMER = "tume-recovery-automatic.timer"
POLICY = STATE / "automatic-policy"
STOP = STATE / "automatic-stop"


def audit():
    return json.loads(run(HELPER, "audit"))["events"]


def invoke(*args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=15)
    return result.returncode, result.stdout + result.stderr


def set_window(boot, start, end):
    with tempfile.NamedTemporaryFile(dir=STATE, mode="w", delete=False) as candidate:
        candidate.write((ASSETS / "policy.example").read_text())
        candidate.write(f"{boot} {start} {end}\n")
    os.replace(candidate.name, POLICY)


def failed():
    run("/usr/bin/systemctl", "kill", "--kill-whom=main", "--signal=KILL", UNIT)
    wait_for(lambda: service("ActiveState") == "failed")


def root_approval():
    child, terminal = pty.fork()
    if child == 0:
        os.execv(HELPER, (HELPER, "approve", UNIT))
    output = b""
    sent = False
    end = time.monotonic() + 5
    try:
        while time.monotonic() < end:
            if not select.select([terminal], [], [], 0.05)[0]:
                continue
            try:
                chunk = os.read(terminal, 4096)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                break
            if not chunk:
                break
            output += chunk
            match = re.search(rb"Type exactly: (approve [0-9a-f]{32})\r?\n> ", output)
            if match and not sent:
                os.write(terminal, match[1] + b"\n")
                sent = True
        else:
            raise AssertionError("root approval prompt timed out")
        _, status = os.waitpid(child, 0)
    finally:
        os.close(terminal)
    assert status == 0, output.decode()
    return re.search(rb"Approval ([0-9a-f]{32})", output)[1].decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--disposable-vm", action="store_true", required=True)
    parser.add_argument("manual_executor")
    parser.add_argument("automatic_executor")
    options = parser.parse_args()
    if os.getuid() != 0:
        parser.error("run the explicitly authorized trial as VM root")
    run("/usr/bin/systemd-detect-virt", "--vm")
    os.environ.pop("SUDO_UID", None)
    if any(path.exists() for path in (Path(AUTO), POLICY, STOP)):
        parser.error("trial requires a completed manual trial and fresh automatic paths")
    install(options.manual_executor, HELPER, "0755")
    assert len(audit()) == 11, "expected the completed manual trial audit"
    install(options.automatic_executor, AUTO, "0755")
    for name in (AUTO_SERVICE, AUTO_TIMER):
        install(ASSETS.parent / "systemd" / name, Path("/etc/systemd/system") / name, "0644")
    run("/usr/bin/systemctl", "daemon-reload")
    run("/usr/bin/systemd-analyze", "verify", AUTO_SERVICE, AUTO_TIMER)
    status, output = invoke("/usr/bin/systemctl", "is-active", AUTO_TIMER)
    assert status != 0 and "inactive" in output
    expect_result(invoke("/usr/sbin/runuser", "-u", "nobody", "--", AUTO), 3, "TrustedRootRequired")
    expect_result(invoke(AUTO, "unexpected"), 2, "InvalidUsage")
    print("PASS root-only no-argument entry, compatible manual audit, and timer inactive", flush=True)

    failed()
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip().replace("-", "")
    now = time.clock_gettime_ns(time.CLOCK_BOOTTIME) // 1_000_000
    expect_result(invoke(AUTO), 0, "AutomaticPolicyDisabled")
    try:
        set_window("e" * 32, now, now + 60_000)
        expect_result(invoke(AUTO), 0, "MaintenanceWindowClosed")
        set_window(boot, 0, 1)
        expect_result(invoke(AUTO), 0, "MaintenanceWindowClosed")
        set_window(boot, now, now + 60_000)
        STOP.touch()
        expect_result(invoke(AUTO), 0, "AutomaticPolicyDisabled")
        STOP.unlink()
        with (STATE / ".executor.lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            expect_result(invoke(AUTO), 3, "TargetBusy")
        assert service("ActiveState") == "failed" and len(audit()) == 11
        print("PASS absent, wrong-boot, expired, stopped and locked cases caused zero effects", flush=True)

        approval = root_approval()
        expect_result(invoke(AUTO), 0, "ApprovalAlreadyPending")
        expect_result(invoke(HELPER, "execute", approval), 0, "Restart verified")
        assert service("ActiveState") == "active"
        failed()
        print("PASS automatic attempt preserved the explicit manual approval", flush=True)

        run("/usr/bin/systemctl", "start", AUTO_TIMER)
        wait_for(lambda: service("ActiveState") == "active")
        run("/usr/bin/systemctl", "stop", AUTO_TIMER)
        wait_for(lambda: run("/usr/bin/systemctl", "show", "--value", "--property=ActiveState", AUTO_SERVICE).strip() == "inactive")
        events = audit()
        assert [event["kind"] for event in events[-3:]] == ["automatic_intent", "dispatch", "finished"]
        assert events[-1]["evidence"]["functional"] == "passed"
        assert events[-1]["evidence"]["invocation"]
        assert all(not event["rollback_eligible"] for event in events[-3:])
        assert all(event["identity"]["actor"] == 0 for event in events[-3:])
        failed()
        expect_result(invoke(AUTO), 0, "AutomaticRateLimited")
        assert service("ActiveState") == "failed" and audit() == events
        print("PASS opt-in timer issued one verified start and durable same-boot rate limit", flush=True)
    finally:
        STOP.touch()
        run("/usr/bin/systemctl", "stop", AUTO_TIMER)
        POLICY.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
