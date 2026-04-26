import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from pkvm_regress.artifacts import create_run
from pkvm_regress.collectors import build_collector_plan


class CollectorPlanTests(unittest.TestCase):
    def test_collector_plan_writes_live_host_logs_under_run_dir(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            run = create_run(Path(tmpdir), "T12-A1", vfio_dev="0000:01:00.0")
            plan = build_collector_plan(run)

            names = [collector.name for collector in plan.collectors]
            self.assertEqual(names, ["host-dmesg-live", "host-journal-live"])

            commands = "\n".join(collector.command for collector in plan.collectors)
            self.assertIn("dmesg -wT", commands)
            self.assertIn("journalctl -kf", commands)
            self.assertIn(str(run.logs_dir / "host-dmesg-live.log"), commands)
            self.assertIn(str(run.logs_dir / "host-journal-live.log"), commands)
            self.assertIn("stdbuf -oL", commands)

    def test_collector_plan_has_sync_barrier_and_final_snapshot_commands(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            run = create_run(Path(tmpdir), "T12-A2b", vfio_dev="0000:01:00.0")
            plan = build_collector_plan(run)

            self.assertEqual(plan.sync_command, "sync")
            final_commands = "\n".join(plan.final_snapshot_commands)
            self.assertIn("dmesg -T", final_commands)
            self.assertIn("host-dmesg-final.log", final_commands)
            self.assertIn("trace", final_commands)
            self.assertNotIn("sh -c 'cat", final_commands)


if __name__ == "__main__":
    unittest.main()
