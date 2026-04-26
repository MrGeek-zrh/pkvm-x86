import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from pkvm_regress.commands import build_case_plan


class CommandPlanTests(unittest.TestCase):
    def test_a1_plan_invokes_run_crosvm_with_protected_vfio(self):
        plan = build_case_plan("T12-A1", vfio_dev="0000:01:00.0")

        joined = "\n".join(plan.commands)
        self.assertIn("PROTECTED=1", joined)
        self.assertIn("SETUP_NET=0", joined)
        self.assertIn("VFIO_DEV=0000:01:00.0", joined)
        self.assertIn("./scripts/run-crosvm.sh", joined)
        self.assertIn("ptdev BAR revoked", "\n".join(plan.required_patterns))

    def test_a2b_requires_explicit_host_bar_touch_guard(self):
        with self.assertRaisesRegex(PermissionError, "--allow-host-bar-touch"):
            build_case_plan("T12-A2b", vfio_dev="0000:01:00.0")

        plan = build_case_plan("T12-A2b", vfio_dev="0000:01:00.0", allow_host_bar_touch=True)

        self.assertIn("/sys/bus/pci/devices/0000:01:00.0/resource", "\n".join(plan.commands))
        self.assertIn("deny host BAR remap", "\n".join(plan.required_patterns))


if __name__ == "__main__":
    unittest.main()
