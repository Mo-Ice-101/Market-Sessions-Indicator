"""Verify symbol calibration and valid split volumes for non-gold CFDs."""
import test_entry_timeframe
import unittest


class SymbolSpecificationTests(unittest.TestCase):
    def test_contract_multiplier_scales_linear_pnl(self):
        replay = test_entry_timeframe.EntryTimeframeTests().replay
        full = replay(5)
        small = replay(5, ("--contract-size", "1"))
        self.assertIn("contract=100", full)
        self.assertIn("contract=1", small)
        self.assertIn("Trades 1 ", small)

    def test_painx_volume_and_spread_point_specifications(self):
        output = test_entry_timeframe.EntryTimeframeTests().replay(
            5, ("--point", ".01", "--contract-size", "1", "--lots", ".2",
                "--min-lot", ".1", "--lot-step", ".01", "--scale-out-r", "10",
                "--min-stop-distance", "1.91")
        )
        self.assertIn("Point=0.01 contract=1 min lot=0.1 lot step=0.01", output)
        self.assertIn("minimum stop distance=1.91", output)
        self.assertIn("50% at +10R; ATR trail at +2R", output)


if __name__ == "__main__":
    unittest.main()
