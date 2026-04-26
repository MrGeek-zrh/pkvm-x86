import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from pkvm_regress.registry import get_case
from pkvm_regress.report import render_report_skeleton


class ReportTests(unittest.TestCase):
    def test_report_skeleton_contains_environment_cases_and_guard(self):
        report = render_report_skeleton(
            cases=[get_case("T12-A2b")],
            vfio_dev="0000:01:00.0",
            pkvm_ia_commit="9f9531b5e36a",
        )

        self.assertIn("# T12 第一阶段测试记录", report)
        self.assertIn("VFIO_DEV", report)
        self.assertIn("0000:01:00.0", report)
        self.assertIn("T12-A2b", report)
        self.assertIn("--allow-host-bar-touch", report)
        self.assertIn("是否需要新建 Bug issue", report)


if __name__ == "__main__":
    unittest.main()
