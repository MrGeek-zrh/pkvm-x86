import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "pkvm-regress.py"


class CliArtifactTests(unittest.TestCase):
    def test_prepare_run_creates_running_artifact_and_prints_collectors(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "prepare-run",
                    "T12-A1",
                    "--artifacts-root",
                    tmpdir,
                    "--vfio-dev",
                    "0000:01:00.0",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("host-dmesg-live", result.stdout)
            self.assertIn("journalctl -kf", result.stdout)
            run_dirs = list(Path(tmpdir).iterdir())
            self.assertEqual(len(run_dirs), 1)
            status = json.loads((run_dirs[0] / "status.json").read_text())
            self.assertEqual(status["status"], "RUNNING")

    def test_recover_runs_marks_running_artifacts(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            subprocess.run(
                [sys.executable, str(SCRIPT), "prepare-run", "T12-A1", "--artifacts-root", tmpdir],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "recover-runs", "--artifacts-root", tmpdir],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("CRASHED_OR_INTERRUPTED", result.stdout)
            run_dir = next(Path(tmpdir).iterdir())
            self.assertEqual(json.loads((run_dir / "status.json").read_text())["status"], "CRASHED_OR_INTERRUPTED")


if __name__ == "__main__":
    unittest.main()
