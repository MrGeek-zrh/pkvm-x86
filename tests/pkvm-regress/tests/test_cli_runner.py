import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "pkvm-regress.py"


class CliRunnerTests(unittest.TestCase):
    def test_run_shell_creates_artifact_and_captures_output(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "run-shell",
                    "T12-A1",
                    "--artifacts-root",
                    tmpdir,
                    "--no-host-collectors",
                    "--",
                    sys.executable,
                    "-c",
                    "print('login:')",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("status: COMPLETE", result.stdout)
            run_dir = next(Path(tmpdir).iterdir())
            self.assertIn("login:", (run_dir / "logs" / "action-stdout.log").read_text())
            self.assertEqual(json.loads((run_dir / "status.json").read_text())["status"], "COMPLETE")

    def test_run_shell_timeout_leaves_running_for_recovery(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "run-shell",
                    "T12-A1",
                    "--artifacts-root",
                    tmpdir,
                    "--timeout-sec",
                    "0.1",
                    "--no-host-collectors",
                    "--",
                    sys.executable,
                    "-c",
                    "import time; time.sleep(3)",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("timeout", result.stderr)
            run_dir = next(Path(tmpdir).iterdir())
            self.assertEqual(json.loads((run_dir / "status.json").read_text())["status"], "RUNNING")


if __name__ == "__main__":
    unittest.main()
