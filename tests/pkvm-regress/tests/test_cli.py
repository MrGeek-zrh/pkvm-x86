import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "pkvm-regress.py"


class CliTests(unittest.TestCase):
    def test_guard_failure_is_friendly_without_traceback(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "plan", "T12-A2b", "--vfio-dev", "0000:01:00.0"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--allow-host-bar-touch", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
