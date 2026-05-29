import ast
import re
import sys
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_ROOT = SCRIPT_ROOT / "rtl_runtime"
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


class Python36CompatTest(unittest.TestCase):
    def test_rtl_runtime_avoids_known_py36_incompatibilities(self) -> None:
        forbidden_patterns = [
            (r"from __future__ import annotations", "future_annotations"),
            (r"from dataclasses import", "stdlib_dataclasses_import"),
            (r"\b(?:list|dict|tuple|set)\[", "pep585_builtin_generics"),
            (r"\bzip\([^)]*strict\s*=", "zip_strict"),
            (r"[:(, ]\s*[A-Za-z_][A-Za-z0-9_]*\s*\|\s*[A-Za-z_]", "pep604_union"),
            (r"add_subparsers\([^)]*required\s*=", "argparse_required_subparsers"),
        ]

        checked_files = sorted(PACKAGE_ROOT.glob("*.py"))
        self.assertTrue(checked_files)

        violations = []
        for path in checked_files:
            source = path.read_text(encoding="utf-8")
            for pattern, label in forbidden_patterns:
                if re.search(pattern, source):
                    violations.append("%s:%s" % (path.name, label))

            tree = ast.parse(source, filename=str(path))
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                if not isinstance(node.func, ast.Attribute):
                    continue
                if node.func.attr != "write_text":
                    continue
                for keyword in node.keywords:
                    if keyword.arg == "newline":
                        violations.append(
                            "%s:%s" % (path.name, "pathlib_write_text_newline")
                        )

        self.assertEqual(violations, [])


if __name__ == "__main__":
    unittest.main()
