import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from pkvm_regress.artifacts import RunStatus, create_run
from pkvm_regress.runner import run_shell_action


class RunnerTests(unittest.TestCase):
    def test_run_shell_action_captures_stdout_stderr_and_marks_complete(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            run = create_run(Path(tmpdir), "T12-A1", vfio_dev="0000:01:00.0")
            result = run_shell_action(
                run,
                [
                    sys.executable,
                    "-c",
                    "import sys; print('guest login:'); print('host note', file=sys.stderr)",
                ],
            )

            self.assertEqual(result.returncode, 0)
            self.assertEqual(run.status, RunStatus.COMPLETE)
            self.assertIn("guest login:", (run.logs_dir / "action-stdout.log").read_text())
            self.assertIn("host note", (run.logs_dir / "action-stderr.log").read_text())
            summary = json.loads((run.path / "result.json").read_text())
            self.assertEqual(summary["status"], "COMPLETE")
            self.assertEqual(summary["returncode"], 0)

    def test_run_shell_action_marks_failed_on_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            run = create_run(Path(tmpdir), "T12-A1", vfio_dev="0000:01:00.0")
            result = run_shell_action(run, [sys.executable, "-c", "import sys; sys.exit(7)"])

            self.assertEqual(result.returncode, 7)
            self.assertEqual(run.status, RunStatus.FAILED)
            summary = json.loads((run.path / "result.json").read_text())
            self.assertEqual(summary["status"], "FAILED")
            self.assertEqual(summary["returncode"], 7)

    def test_run_shell_action_can_preserve_running_status_for_interrupted_run(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            run = create_run(Path(tmpdir), "T12-A1", vfio_dev="0000:01:00.0")
            with self.assertRaises(TimeoutError):
                run_shell_action(run, [sys.executable, "-c", "import time; time.sleep(3)"], timeout_sec=0.1)

            self.assertEqual(run.status, RunStatus.RUNNING)
            self.assertIn("timeout", (run.logs_dir / "runner-error.log").read_text())


if __name__ == "__main__":
    unittest.main()

class RunnerCollectorTests(unittest.TestCase):
    def test_run_shell_action_starts_collectors_before_action_and_runs_final_snapshot(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            from pkvm_regress.collectors import CollectorCommand, CollectorPlan

            root = Path(tmpdir)
            run = create_run(root, "T12-A1", vfio_dev="0000:01:00.0")
            collector_log = run.logs_dir / "fake-collector.log"
            snapshot_log = run.logs_dir / "fake-final.log"
            plan = CollectorPlan(
                collectors=(
                    CollectorCommand(
                        name="fake-live",
                        command=(
                            f"{sys.executable} -c \"from pathlib import Path; "
                            f"Path(r'{collector_log}').write_text('collector-started\\n'); "
                            "import time; time.sleep(5)\""
                        ),
                        output_path=str(collector_log),
                    ),
                ),
                sync_command=f"{sys.executable} -c \"print('sync-ok')\"",
                final_snapshot_commands=(f"{sys.executable} -c \"from pathlib import Path; Path(r'{snapshot_log}').write_text('snapshot\\n')\"",),
            )

            result = run_shell_action(
                run,
                [
                    sys.executable,
                    "-c",
                    f"from pathlib import Path; assert Path(r'{collector_log}').exists(); print('action-ok')",
                ],
                collector_plan=plan,
            )

            self.assertEqual(result.returncode, 0)
            self.assertIn("collector-started", collector_log.read_text())
            self.assertIn("snapshot", snapshot_log.read_text())
            self.assertIn("action-ok", (run.logs_dir / "action-stdout.log").read_text())

class RunnerCollectorFailureTests(unittest.TestCase):
    def test_run_shell_action_refuses_action_when_collector_exits_early(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            from pkvm_regress.collectors import CollectorCommand, CollectorPlan

            run = create_run(Path(tmpdir), "T12-A1", vfio_dev="0000:01:00.0")
            plan = CollectorPlan(
                collectors=(
                    CollectorCommand(
                        name="dead-live",
                        command=f"{sys.executable} -c \"import sys; sys.exit(3)\"",
                        output_path=str(run.logs_dir / "dead-live.log"),
                    ),
                ),
                sync_command="sync",
                final_snapshot_commands=(),
            )

            with self.assertRaisesRegex(RuntimeError, "collector dead-live exited"):
                run_shell_action(run, [sys.executable, "-c", "print('must-not-run')"], collector_plan=plan)

            self.assertEqual(run.status, RunStatus.FAILED)
            self.assertIn("collector dead-live exited", (run.logs_dir / "runner-error.log").read_text())
            self.assertFalse((run.logs_dir / "action-stdout.log").exists())
