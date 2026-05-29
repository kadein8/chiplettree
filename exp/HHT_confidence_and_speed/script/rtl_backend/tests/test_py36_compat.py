import re
import sys
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_ROOT = SCRIPT_ROOT / "rtl_backend"
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


class Python36CompatTest(unittest.TestCase):
    def test_rtl_backend_avoids_known_py36_incompatibilities(self) -> None:
        forbidden_patterns = [
            (r"from __future__ import annotations", "future_annotations"),
            (r"from dataclasses import", "stdlib_dataclasses_import"),
            (r"\b(?:list|dict|tuple|set)\[", "pep585_builtin_generics"),
            (r"\bzip\([^)]*strict\s*=", "zip_strict"),
            (r"[:(, ]\s*[A-Za-z_][A-Za-z0-9_]*\s*\|\s*[A-Za-z_]", "pep604_union"),
        ]

        checked_files = sorted(PACKAGE_ROOT.glob("*.py"))
        self.assertTrue(checked_files)

        violations = []
        for path in checked_files:
            source = path.read_text(encoding="utf-8")
            for pattern, label in forbidden_patterns:
                if re.search(pattern, source):
                    violations.append("%s:%s" % (path.name, label))

        self.assertEqual(violations, [])


if __name__ == "__main__":
    unittest.main()
