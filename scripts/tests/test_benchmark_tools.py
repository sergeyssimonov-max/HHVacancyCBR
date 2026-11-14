"""Prevent false-positive equivalence when baseline inputs or Python flags change."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BenchmarkToolTests(unittest.TestCase):
    def check_empty_baseline(self, script):
        with tempfile.TemporaryDirectory(prefix="benchmark guard ") as temporary:
            root = Path(temporary)
            marker = root / "compiler-invoked"
            stub = root / "clang"
            stub.write_text("#!/bin/sh\nprintf invoked > " + shlex.quote(str(marker)) + "\nexit 99\n")
            stub.chmod(0o755)
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"])
            result = subprocess.run(["/bin/bash", str(ROOT / "scripts/benchmarks" / script),
                                     str(root / "benchmark"), ""], env=environment,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("Source directory does not exist", result.stderr)
            self.assertFalse(marker.exists(), "An invalid baseline reached the compiler")

    def test_pdf_build_rejects_empty_baseline_before_compilation(self):
        self.check_empty_baseline("build_pdf_equivalence.sh")

    def test_filter_build_rejects_empty_baseline_before_compilation(self):
        self.check_empty_baseline("build_filter_benchmarks.sh")

    def compare_with_optimized_python(self, same):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for version, text in [("before", "original"), ("after", "original" if same else "changed")]:
                folder = root / version
                folder.mkdir()
                (folder / "manifest.json").write_text(json.dumps({"documents": [{"pages": 1, "text": text}]}))
            return subprocess.run([sys.executable, "-O", str(ROOT / "scripts/benchmarks/compare_pdf_equivalence.py"),
                                   str(root / "before"), str(root / "after")], capture_output=True, text=True)

    def test_pdf_mismatch_fails_with_python_optimization(self):
        result = self.compare_with_optimized_python(same=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("equivalence differs", result.stderr)
        self.assertNotIn("PASS", result.stdout)

    def test_equal_pdf_manifests_pass_with_python_optimization(self):
        result = self.compare_with_optimized_python(same=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS: 1 PDFs, 1 pages", result.stdout)


if __name__ == "__main__":
    unittest.main()
