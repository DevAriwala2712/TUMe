#!/usr/bin/env python3
"""Disposable systemd service with a socket round trip and opt-in fault fixtures."""

import os
from pathlib import Path
import socket
import time


def main():
    response = b"TUME-PONG 1\n"
    if Path("/run/tume-recovery-demo.bad").is_file():
        response = b"TUME-BROKEN\n"

    with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as listener:
        listener.bind("/run/tume-recovery-demo/probe.sock")
        listener.listen(4)
        if Path("/run/tume-recovery-demo.slow").is_file():
            time.sleep(3)
        notify_path = os.environ["NOTIFY_SOCKET"]
        if notify_path.startswith("@"):
            notify_path = "\0" + notify_path[1:]
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as notify:
            notify.sendto(b"READY=1", notify_path)

        while True:
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(0.5)
                try:
                    if connection.recv(64) == b"TUME-PING 1\n":
                        connection.sendall(response)
                except (TimeoutError, BrokenPipeError, ConnectionResetError):
                    pass


if __name__ == "__main__":
    main()
