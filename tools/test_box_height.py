"""Verify price-height filters before confirmation and order simulation."""
from pathlib import Path
import subprocess
import sys
import unittest

import test_entry_timeframe

ROOT = Path(__file__).resolve().parents[1]


class BoxHeightTests(unittest.TestCase):
    def test_inclusive_minimum_exclusive_maximum(self):
        replay = test_entry_timeframe.EntryTimeframeTests().replay
        # Synthetic opening box is exactly 100.1 - 99.9 = 0.2.
        self.assertIn("Trades 1 ", replay(5, ("--min-box-height", ".2")))
        self.assertIn("Trades 0 ", replay(5, ("--min-box-height", ".201")))
        self.assertIn("Trades 0 ", replay(5, ("--max-box-height", ".2")))
        self.assertIn("Trades 1 ", replay(5, ("--max-box-height", ".201")))

    def test_invalid_limits_rejected_before_data_read(self):
        for flags in (
            ("--min-box-height", "-1"), ("--min-box-height", "nan"),
            ("--max-box-height", "inf"), ("--max-box-height", "0"),
            ("--min-box-height", "5", "--max-box-height", "5"),
        ):
            result = subprocess.run(
                [sys.executable, str(ROOT / "tools/sim_ea.py"), "unused.csv", *flags],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("box-height must", result.stderr)


if __name__ == "__main__":
    unittest.main()
