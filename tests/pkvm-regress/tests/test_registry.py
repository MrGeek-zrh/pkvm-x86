import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from pkvm_regress.registry import get_case, iter_cases


class CaseRegistryTests(unittest.TestCase):
    def test_registry_contains_split_host_bar_cases(self):
        passive = get_case("T12-A2a")
        injection = get_case("T12-A2b")

        self.assertEqual(passive.mode, "agent-runbook")
        self.assertEqual(passive.priority, "P0")
        self.assertFalse(passive.requires_allow_host_bar_touch)
        self.assertIn("INCONCLUSIVE", passive.miss_policy)

        self.assertEqual(injection.mode, "agent-runbook")
        self.assertEqual(injection.priority, "P1")
        self.assertTrue(injection.requires_allow_host_bar_touch)
        self.assertIn("--allow-host-bar-touch", injection.guard)

    def test_first_wave_order_keeps_injection_after_safe_cases(self):
        case_ids = [case.case_id for case in iter_cases(first_wave_only=True)]

        self.assertLess(case_ids.index("T12-A2a"), case_ids.index("T12-A2b"))
        self.assertLess(case_ids.index("T12-B1"), case_ids.index("T12-A2b"))
        self.assertLess(case_ids.index("T12-R1"), case_ids.index("T12-A2b"))


if __name__ == "__main__":
    unittest.main()
