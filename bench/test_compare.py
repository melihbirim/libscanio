"""Exercise the benchmark runner on the host OS, including Windows CI."""
import sys
import unittest

from compare import run_once


class RunnerTests(unittest.TestCase):
    def test_peak_memory_units_and_output(self):
        result = run_once([
            sys.executable, "-c",
            "data = bytearray(64 * 1024 * 1024); print('ROWS=7')",
        ])
        self.assertEqual(result["rc"], 0)
        self.assertEqual(result["out"].strip(), "ROWS=7")
        # Wide bounds tolerate interpreter overhead but catch bytes/KB
        # being reported as MB, and a lost peak after the child exits.
        self.assertGreater(result["rss_mb"], 50)
        self.assertLess(result["rss_mb"], 512)

    def test_child_failure_preserves_stderr(self):
        result = run_once([
            sys.executable, "-c",
            "import sys; print('child failed', file=sys.stderr); sys.exit(7)",
        ])
        self.assertEqual(result["rc"], 7)
        self.assertIn("child failed", result["err"])

    def test_runner_failure_preserves_stderr(self):
        with self.assertRaisesRegex(RuntimeError, "FileNotFoundError"):
            run_once(["/nonexistent-libscanio-review-test/executable"])


if __name__ == "__main__":
    unittest.main()
