"""Process-group cleanup survives abrupt loss of the supervising driver."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent
CHILD = r'''
from pathlib import Path
import os, subprocess, sys, time
subprocess.Popen([sys.executable, "-c", "from pathlib import Path; import sys,time; time.sleep(.6); Path(sys.argv[1]).touch()", sys.argv[2]])
Path(sys.argv[1]).write_text(str(os.getpgrp()))
time.sleep(4)
'''
DRIVER = r'''
import sys
sys.path.insert(0, sys.argv[1])
from processes import run
run([sys.executable, "-c", sys.argv[2], sys.argv[3], sys.argv[4]], timeout=5)
'''


class ParentLifetimeTests(unittest.TestCase):
    def check_parent_loss(self, termination):
        with tempfile.TemporaryDirectory(prefix="supervisor-parent-") as temporary:
            ready = Path(temporary) / "ready"
            marker = Path(temporary) / "orphan"
            group = None
            cleaned = False
            driver = subprocess.Popen([sys.executable, "-c", DRIVER, str(ROOT), CHILD, str(ready), str(marker)],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 3
                while not ready.is_file() and driver.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(ready.is_file(), "supervised child never became ready")
                group = int(ready.read_text())
                self.assertIsNone(driver.poll())
                os.kill(driver.pid, termination)
                driver.wait(timeout=3)
                time.sleep(.8)
                self.assertFalse(marker.exists(), "parent loss left a live supervised descendant")
                cleaned = True
            finally:
                if driver.poll() is None:
                    driver.kill()
                driver.wait(timeout=3)
                if group is not None and not cleaned:
                    try:
                        os.killpg(group, signal.SIGKILL)
                    except (ProcessLookupError, PermissionError):
                        pass

    def test_sigterm_of_driver_cleans_its_supervised_group(self):
        self.check_parent_loss(signal.SIGTERM)

    def test_sigkill_of_driver_cleans_its_supervised_group(self):
        self.check_parent_loss(signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
