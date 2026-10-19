"""Bound local tooling commands and reap their process groups."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import tempfile
import time
from collections.abc import Sequence

MAX_OUTPUT_BYTES = 1024 * 1024
_GUARD = """
import os, signal, subprocess, sys, threading
def parent_lifetime():
    while os.read(int(sys.argv[2]), 1):
        pass
    os.killpg(os.getpgrp(), signal.SIGKILL)
threading.Thread(target=parent_lifetime, daemon=True).start()
child = subprocess.Popen(sys.argv[3:])
code = child.wait()
os.write(int(sys.argv[1]), str(code).encode())
while True:
    signal.pause()
"""


def run(argv: Sequence[str], *, timeout: float = 60, cwd=None, env=None, stdin=None):
    report, report_writer = os.pipe()
    # EOF lets the guardian clean up even if this driver is killed abruptly.
    lifetime, lifetime_writer = os.pipe()
    os.set_blocking(report, False)
    try:
        with tempfile.TemporaryFile() as output:
            # The guardian keeps the group ID reserved and signalable after
            # command exit, including Darwin's otherwise unsignalable zombies.
            process = subprocess.Popen(
                [sys.executable, "-c", _GUARD, str(report_writer), str(lifetime), *argv],
                cwd=cwd, env=env, stdin=stdin, stdout=output,
                stderr=subprocess.STDOUT, start_new_session=True,
                pass_fds=(report_writer, lifetime),
            )
            os.close(lifetime)
            lifetime = -1
            os.close(report_writer)
            report_writer = -1
            deadline = time.monotonic() + timeout
            try:
                while True:
                    if os.fstat(output.fileno()).st_size > MAX_OUTPUT_BYTES:
                        raise RuntimeError(f"command output exceeds 1 MiB: {argv[0]}")
                    try:
                        status = os.read(report, 64)
                    except BlockingIOError:
                        status = b""
                    if status:
                        code = int(status)
                        break
                    completed = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                    if completed is not None:
                        raise RuntimeError(f"command guardian exited without a result: {argv[0]}")
                    if time.monotonic() >= deadline:
                        raise subprocess.TimeoutExpired(argv, timeout)
                    time.sleep(.01)
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    # Darwin returns EPERM for a group of zombies only. An
                    # active guardian cannot take this path.
                    completed = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                    if completed is None:
                        raise
                finally:
                    process.wait(timeout=5)
            if os.fstat(output.fileno()).st_size > MAX_OUTPUT_BYTES:
                raise RuntimeError(f"command output exceeds 1 MiB: {argv[0]}")
            output.seek(0)
            text = output.read(MAX_OUTPUT_BYTES).decode("utf-8", "replace")
            return code, text
    finally:
        os.close(report)
        os.close(lifetime_writer)
        if lifetime != -1:
            os.close(lifetime)
        if report_writer != -1:
            os.close(report_writer)
