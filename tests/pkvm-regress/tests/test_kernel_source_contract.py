import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PTDEV_C = ROOT / "pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c"


def _function_body(source: str, name: str) -> str:
    search_from = 0
    while True:
        start = source.index(name, search_from)
        brace = source.index("{", start)
        declaration = source[start:brace]
        if ";" not in declaration:
            break
        search_from = start + len(name)

    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"function {name} body not found")


class KernelSourceContractTests(unittest.TestCase):
    def test_revoke_uses_direct_bar_metadata_ranges_not_whole_bar(self):
        source = PTDEV_C.read_text()
        body = _function_body(source, "pkvm_revoke_ptdev_bars_locked")

        self.assertIn("ptdev->mmio_metadata.ranges", body)
        self.assertIn("pkvm_ptdev_range_hpa_locked", body)
        self.assertIn("ptdev MMIO range revoked", body)
        self.assertNotIn("bar->hpa, bar->size", body)

    def test_restore_uses_recorded_mmio_ranges_not_whole_bar_mask(self):
        source = PTDEV_C.read_text()
        body = _function_body(source, "pkvm_restore_ptdev_bars_locked")
        helper = _function_body(source, "pkvm_restore_ptdev_mmio_ranges_locked")

        self.assertIn("pkvm_restore_ptdev_mmio_ranges_locked", body)
        self.assertIn("touched_mmio_ranges", helper)
        self.assertIn("ptdev MMIO range restored", helper)
        self.assertNotIn("pkvm_host_ept_restore_mmio_idmap(bar->hpa, bar->size", helper)


if __name__ == "__main__":
    unittest.main()
