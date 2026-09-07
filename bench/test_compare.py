"""Exercise the benchmark runner on the host OS, including Windows CI."""
import sys
import unittest
import json
import tempfile
import contextlib
import io
from unittest.mock import patch

from compare import (run_once, measure, main, expected_result, fixture_row,
                     write_fixture, engine_command, dependencies, ENGINES)


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

    def test_every_repetition_is_checked(self):
        samples = [{"rc": 0, "out": json.dumps({"rows": n}), "secs": .1, "rss_mb": 1}
                   for n in (2, 1)]
        with patch("compare.run_once", side_effect=samples):
            with self.assertRaisesRegex(ValueError, "expected 2, got 1"):
                measure([], 2, {"rows": 2})

    def test_missing_result_is_a_failure(self):
        with patch("compare.run_once", return_value={
                "rc": 0, "out": "{}", "secs": .1, "rss_mb": 1}):
            with self.assertRaisesRegex(ValueError, "expected 2"):
                measure([], 1, {"rows": 2})

    def test_warm_uses_query_timer(self):
        with patch("compare.run_once", return_value={
                "rc": 0, "out": '{"rows": 2, "query_secs": 0.01}',
                "secs": 9, "rss_mb": 1}):
            self.assertEqual(measure([], 1, {"rows": 2}, timing="warm")[0], .01)

    def test_failed_engine_fails_the_matrix(self):
        with patch.object(sys, "argv", ["compare.py", "--engines", "native-python",
                                       "--workloads", "stream", "--rows", "1"]), \
             patch("compare.dependencies", return_value=({"native-python": True}, {})), \
             patch("compare.measure", side_effect=RuntimeError("broken engine")), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main(), 1)

    def test_workload_drivers_against_fixture(self):
        available, _ = dependencies("")
        with tempfile.TemporaryDirectory() as tmp:
            for fmt in ("csv", "ndjson"):
                path = write_fixture(tmp, 7, fmt)
                for workload, entries in ENGINES.items():
                    for engine, _ in entries:
                        if not available[engine]:
                            continue
                        if workload == "arrow" and engine in ("libscanio-python", "polars") and not available["pyarrow"]:
                            continue
                        with self.subTest(format=fmt, workload=workload, engine=engine):
                            command = engine_command(engine, workload, path, fmt, "cold")
                            measure(command, 1, expected_result(7, workload))
                            if workload == "arrow":
                                result = run_once(command + ["--verify"])
                                self.assertEqual(result["rc"], 0, result["err"])
                                values = json.loads(result["out"])["values"]
                                self.assertEqual(sorted(values, key=lambda r: r["trip_id"]),
                                                 [fixture_row(i) for i in (0, 3, 6)])


if __name__ == "__main__":
    unittest.main()
