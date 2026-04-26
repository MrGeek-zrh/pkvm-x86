import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from pkvm_regress.artifacts import (
    RunStatus,
    create_run,
    find_incomplete_runs,
    mark_incomplete_runs,
)


class ArtifactTests(unittest.TestCase):
    def test_create_run_writes_running_status_and_metadata(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            run = create_run(Path(tmpdir), "T12-A1", vfio_dev="0000:01:00.0")

            self.assertTrue(run.path.exists())
            self.assertEqual(run.status, RunStatus.RUNNING)
            self.assertEqual(run.status_path.read_text(), json.dumps({"status": "RUNNING"}, indent=2) + "\n")

            metadata = json.loads(run.metadata_path.read_text())
            self.assertEqual(metadata["case_id"], "T12-A1")
            self.assertEqual(metadata["vfio_dev"], "0000:01:00.0")
            self.assertIn("created_at_utc", metadata)

            expected_dirs = ["trace", "logs"]
            for name in expected_dirs:
                self.assertTrue((run.path / name).is_dir())

    def test_find_and_mark_incomplete_runs(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            running = create_run(root, "T12-A2b", vfio_dev="0000:01:00.0")
            complete = create_run(root, "T12-A1", vfio_dev="0000:01:00.0")
            complete.write_status(RunStatus.COMPLETE)

            incomplete = find_incomplete_runs(root)
            self.assertEqual([run.run_id for run in incomplete], [running.run_id])

            marked = mark_incomplete_runs(root)
            self.assertEqual([run.run_id for run in marked], [running.run_id])
            self.assertEqual(json.loads(running.status_path.read_text())["status"], "CRASHED_OR_INTERRUPTED")
            self.assertIn("CRASHED_OR_INTERRUPTED", (running.path / "report.md").read_text())


if __name__ == "__main__":
    unittest.main()
