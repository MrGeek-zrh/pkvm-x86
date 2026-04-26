import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from pkvm_regress.logscan import scan_forbidden_signatures, scan_required_patterns


class LogScanTests(unittest.TestCase):
    def test_forbidden_scan_reports_signature_and_line_number(self):
        log = "boot ok\nDMAR: [DMA Read NO_PASID] fault\nsoft lockup on CPU\n"

        findings = scan_forbidden_signatures(log)

        self.assertEqual([finding.signature for finding in findings], ["DMA Read NO_PASID", "soft lockup"])
        self.assertEqual([finding.line_no for finding in findings], [2, 3])

    def test_required_patterns_report_missing_entries(self):
        log = "pkvm: ptdev MMIO range revoked bdf=0x100 bar=0 hpa=0x1 size=0x1000\n"

        result = scan_required_patterns(log, ["ptdev MMIO range revoked", "ptdev MMIO range restored"])

        self.assertEqual(result.present, ["ptdev MMIO range revoked"])
        self.assertEqual(result.missing, ["ptdev MMIO range restored"])


if __name__ == "__main__":
    unittest.main()
