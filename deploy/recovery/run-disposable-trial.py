#!/usr/bin/env python3
"""Install and exercise T3 on an authorized, fresh disposable Linux VM."""

import argparse
import errno
import json
import os
from pathlib import Path
import pty
import pwd
import re
import secrets
import select
import signal
import subprocess
import time

UNIT = "tume-recovery-demo.service"
HELPER = "/usr/local/libexec/tume-recovery-executor"
STATE = Path("/var/lib/tume-recovery")
BAD = Path("/run/tume-recovery-demo.bad")
SLOW = Path("/run/tume-recovery-demo.slow")
GROUP = "tume-recovery-operators"
USER = "tume-recovery-pilot"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=10, **kwargs).stdout


def install(source, destination, mode):
    run("/usr/bin/install", "-o", "root", "-g", "root", "-m", mode, source, destination)


def service(property_name):
    return run("/usr/bin/systemctl", "show", "--value", f"--property={property_name}", UNIT).strip()


def wait_for(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if result := predicate():
            return result
        time.sleep(0.02)
    raise AssertionError("timed out waiting for expected trial state")


def child_for(approval):
    expected = [os.fsencode(HELPER), b"execute", approval.encode(), b""]
    for process in Path("/proc").iterdir():
        if not process.name.isdigit():
            continue
        try:
            if (process / "cmdline").read_bytes().split(b"\0") != expected:
                continue
            parent = (process / "stat").read_text().rsplit(")", 1)[1].split()[1]
            if (Path("/proc") / parent / "exe").readlink() == Path("/usr/bin/sudo"):
                return int(process.name)
        except (FileNotFoundError, ProcessLookupError):
            continue
    return None


def as_operator(password, *args, crash=False):
    operator = pwd.getpwnam(USER)
    child, terminal = pty.fork()
    if child == 0:
        os.initgroups(USER, operator.pw_gid)
        os.setgid(operator.pw_gid)
        os.setuid(operator.pw_uid)
        os.execve("/usr/bin/sudo", ("sudo", HELPER, *args), {
            "PATH": "/usr/bin:/bin", "LC_ALL": "C", "TERM": "dumb", "HOME": operator.pw_dir,
        })

    deadline = time.monotonic() + 15
    output = b""
    sent_password = False
    sent_confirmation = False
    killed = False
    try:
        while time.monotonic() < deadline:
            if crash and sent_password and not killed and service("ActiveState") == "activating":
                os.kill(wait_for(lambda: child_for(args[1]), timeout=1), signal.SIGKILL)
                killed = True
            if not select.select([terminal], [], [], 0.03)[0]:
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
            if not sent_password and b"password for " in output:
                os.write(terminal, password.encode() + b"\n")
                sent_password = True
            match = re.search(rb"Type exactly: ((?:approve|reconcile) [0-9a-f]{32})\r?\n> ", output)
            if match and not sent_confirmation:
                os.write(terminal, match[1] + b"\n")
                sent_confirmation = True
        else:
            raise AssertionError("sudo recovery trial command exceeded deadline")
        _, status = os.waitpid(child, 0)
    finally:
        os.close(terminal)
    sanitized = output.decode(errors="replace").replace(password, "[redacted]")
    if not sent_password or (crash and not killed):
        raise AssertionError(f"trial missed its authentication or crash checkpoint\n{sanitized}")
    return os.waitstatus_to_exitcode(status), sanitized


def expect_result(result, status, message):
    actual, output = result
    if actual != status or message not in output:
        raise AssertionError(f"expected status {status} and {message!r}, got {actual}\n{output}")
    return output


def approve(password):
    output = expect_result(as_operator(password, "approve", UNIT), 0, "Expires at boot time")
    return re.search(r"Approval ([0-9a-f]{32})", output)[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--disposable-vm", action="store_true", required=True)
    parser.add_argument("cli")
    parser.add_argument("executor")
    options = parser.parse_args()
    if os.getuid() != 0:
        parser.error("run the explicitly authorized trial as VM root")
    run("/usr/bin/systemd-detect-virt", "--vm")
    os.environ.pop("SUDO_UID", None)

    assets = Path(__file__).resolve().parent
    unit_path = Path("/etc/systemd/system") / UNIT
    sudoers = Path("/etc/sudoers.d/tume-recovery")
    if any(path.exists() for path in (STATE, BAD, SLOW, unit_path, sudoers, Path(HELPER))):
        parser.error("trial requires a fresh disposable VM without T3 files")

    run("/usr/bin/install", "-d", "-m", "0755", "/usr/local/libexec")
    run("/usr/bin/install", "-d", "-m", "0700", str(STATE))
    install(options.executor, HELPER, "0755")
    install(assets / "tume-recovery-demo.py", "/usr/local/libexec/tume-recovery-demo.py", "0644")
    install(assets.parent / "systemd" / UNIT, unit_path, "0644")
    run("/usr/bin/systemctl", "daemon-reload")
    run("/usr/sbin/groupadd", "--system", GROUP)
    run("/usr/sbin/useradd", "--create-home", "--shell", "/bin/bash", "--groups", GROUP, USER)
    password = secrets.token_urlsafe(24)
    run("/usr/sbin/chpasswd", input=f"{USER}:{password}\n")
    run("/usr/sbin/visudo", "-cf", assets / "tume-recovery.sudoers")
    install(assets / "tume-recovery.sudoers", sudoers, "0440")
    run("/usr/sbin/visudo", "-c")

    assert "restart-demo revision 1" in run(options.cli, "recovery", "preview", UNIT)
    assert service("ActiveState") == "inactive" and not (STATE / "audit.json").exists()
    expect_result(as_operator(password, "approve", UNIT), 3, "ProcedureDisabled")
    install(assets / "policy.example", STATE / "policy", "0600")
    print("PASS preview caused zero effects and disabled registry refused approval", flush=True)

    first = approve(password)
    different = subprocess.run((HELPER, "execute", first), text=True, capture_output=True, timeout=5)
    expect_result((different.returncode, different.stderr), 3, "ApprovalBindingMismatch")
    assert service("ActiveState") == "inactive"
    expect_result(as_operator(password, "execute", first), 0, "Restart verified")
    first_invocation = service("InvocationID")
    expect_result(as_operator(password, "execute", first), 3, "ApprovalConsumed")
    assert service("InvocationID") == first_invocation
    print("PASS authenticated approval, actor binding, verified restart and replay refusal", flush=True)

    run("/usr/bin/systemctl", "stop", UNIT)
    BAD.touch()
    try:
        bad = approve(password)
        expect_result(as_operator(password, "execute", bad), 5, "functional verification failed")
        assert service("ActiveState") == "active"
    finally:
        BAD.unlink()
    print("PASS systemctl exit zero with an active service and bad probe stayed unverified", flush=True)

    run("/usr/bin/systemctl", "stop", UNIT)
    SLOW.touch()
    try:
        interrupted = approve(password)
        status, output = as_operator(password, "execute", interrupted, crash=True)
        assert status != 0, output
        wait_for(lambda: service("ActiveState") == "active")
        current = service("InvocationID")
        expect_result(as_operator(password, "execute", interrupted), 4, "ReconciliationRequired")
        expect_result(as_operator(password, "reconcile", interrupted), 0, "earlier dispatch may be unknown")
        expect_result(as_operator(password, "execute", interrupted), 3, "ApprovalConsumed")
        assert service("InvocationID") == current
    finally:
        SLOW.unlink()
    print("PASS caller crash left durable intent and read-only reconciliation issued no restart", flush=True)

    records = json.loads(run(HELPER, "audit"))["events"]
    assert [record["kind"] for record in records] == [
        "approval", "intent", "dispatch", "finished",
        "approval", "intent", "dispatch", "finished",
        "approval", "intent", "reconciled",
    ]
    assert records[3]["evidence"]["functional"] == "passed"
    assert records[7]["evidence"]["functional"] == "failed"
    assert records[10]["evidence"]["functional"] == "passed"
    assert all(record["identity"]["actor"] == pwd.getpwnam(USER).pw_uid for record in records)
    print("PASS audit captured 11 bounded records and the authenticated actor", flush=True)


if __name__ == "__main__":
    main()
