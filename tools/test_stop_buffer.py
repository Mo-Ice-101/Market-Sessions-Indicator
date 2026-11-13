"""Portable stop-buffer wiring checks; native EA compilation still requires MT5."""
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]


class StopBufferTests(unittest.TestCase):
    def test_ea_price_units_on_both_entry_paths(self):
        ea = (ROOT / "Market_Sessions_EA.mq5").read_text()
        self.assertIn("input double InpStopBufferPrice = 1.0;", ea)
        self.assertIn("!MathIsValidNumber(InpStopBufferPrice)", ea)
        self.assertIn("InpStopBufferPrice < 0", ea)
        self.assertEqual(ea.count("(buy ? -1 : 1) * InpStopBufferPrice, tick_size, buy)"), 2)
        self.assertNotIn("InpStopBufferPoints", ea)

    def test_mt5_preset_matches_default(self):
        preset = (ROOT / "Market_Sessions_EA_best.set").read_text(encoding="utf-16")
        self.assertIn("InpStopBufferPrice=1.0", preset.splitlines())
        self.assertNotIn("InpStopBufferPoints", preset)

    def test_simulator_rejects_invalid_buffer_before_reading_data(self):
        for value in ("-1", "nan", "inf"):
            with self.subTest(value=value):
                result = subprocess.run(
                    [sys.executable, str(ROOT / "tools/sim_ea.py"), "unused.csv",
                     "--stop-buffer-price", value],
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("--stop-buffer-price must be nonnegative and finite", result.stderr)


if __name__ == "__main__":
    unittest.main()
