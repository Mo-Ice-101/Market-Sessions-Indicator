"""Execute the simulator's management block on controlled executable prices."""
import datetime as dt
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SOURCE = (Path(__file__).resolve().parent / "sim_ea.py").read_text()
BLOCK = SOURCE.split("    # Research mode separates", 1)[1]
BLOCK = "    # Research mode separates" + BLOCK.split("    eq = balance", 1)[0]
BLOCK = "\n".join(line[4:] for line in BLOCK.splitlines())


class HalfAtBreakevenTests(unittest.TestCase):
    def setup_position(self, buy=True, research=True):
        p = dict(buy=buy, entry=100., risk=10., sl=90. if buy else 110.,
                 scaled=False, vol=.04, rem=.04)
        closes = []

        def close(position, price, volume, time, reason):
            position["rem"] = round(position["rem"] - volume, 2)
            closes.append((price, volume, reason))

        scope = dict(
            args=SimpleNamespace(half_at_breakeven=research), os=os,
            atr={dt.datetime(2026, 1, 1): 1.}, t=dt.datetime(2026, 1, 1),
            floor=lambda stamp, minutes: stamp, positions=[p], close=close,
            TRAIL=2., MINLOT=.01,
        )
        return p, closes, scope

    def manage(self, scope, close_price, high, low, spread=0):
        scope.update(c=close_price, h=high, l=low, sp=spread)
        with patch.dict(os.environ, {"BE_R": "1"}, clear=True):
            exec(BLOCK, scope)

    def test_buy_half_at_one_r_no_trail_until_two_r_and_no_second_half(self):
        p, closes, scope = self.setup_position()
        self.manage(scope, 109, 111, 108)
        self.assertEqual(closes, [])  # Wick at 1R is insufficient.
        self.manage(scope, 110, 111, 109)
        self.assertEqual(closes, [(110, .02, "BE-half")])
        self.assertEqual(p["sl"], 100)
        self.manage(scope, 119, 119, 118)
        self.assertEqual(p["sl"], 100)  # Not ATR=117 before 2R.
        self.manage(scope, 120, 120, 119)
        self.assertEqual(p["sl"], 118)
        self.assertEqual(p["rem"], .02)
        self.assertEqual(len(closes), 1)
        self.manage(scope, 119, 119, 118.5)
        self.assertTrue(p["trail_armed"])  # Stays armed on retracement.
        self.assertEqual(p["sl"], 118)  # Stop never loosens.

    def test_sell_uses_ask_for_break_even_and_two_r(self):
        p, closes, scope = self.setup_position(buy=False)
        self.manage(scope, 90, 91, 89.8, .2)
        self.assertEqual(closes, [])  # Bid at 1R, ask still above.
        self.manage(scope, 89.8, 90, 89.5, .2)
        self.assertEqual(closes, [(90, .02, "BE-half")])
        self.assertEqual(p["sl"], 100)
        self.manage(scope, 80.5, 81, 80, .2)
        self.assertEqual(p["sl"], 100)  # Bid touched 2R but ask did not.
        self.manage(scope, 80, 81, 79.8, .2)
        self.assertAlmostEqual(p["sl"], 82.2)
        self.assertEqual(len(closes), 1)

    def test_standard_mode_still_closes_half_at_two_r(self):
        p, closes, scope = self.setup_position(research=False)
        self.manage(scope, 110, 110, 109)
        self.assertEqual(p["sl"], 100)
        self.assertEqual(closes, [])
        self.manage(scope, 120, 120, 119)
        self.assertEqual(closes, [(120, .02, "2R")])
        self.assertEqual(p["sl"], 118)


if __name__ == "__main__":
    unittest.main()
