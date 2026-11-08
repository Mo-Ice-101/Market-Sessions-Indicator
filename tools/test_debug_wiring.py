"""Portable checks of opt-in session and broker diagnostic wiring."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class DebugWiringTests(unittest.TestCase):
    def test_debug_is_enabled_in_ea_and_preset(self):
        source = (ROOT / "Market_Sessions_EA.mq5").read_text()
        preset = (ROOT / "Market_Sessions_EA_best.set").read_text(encoding="utf-16")
        self.assertIn("input bool InpDebugSignals = true;", source)
        self.assertIn("InpDebugSignals=true", preset.splitlines())
        self.assertIn("if(InpDebugSignals)", source)

    def test_debug_covers_signals_and_broker_conditions(self):
        source = (ROOT / "Market_Sessions_EA.mq5").read_text()
        for text in ("opening M15 complete", "no breakout: M5 bar",
                     "historical breakout", "session open=%s next open=%s",
                     "broker minimum=", "requested market lots=",
                     "margin: market=", "response: sent=", "Submitting once"):
            with self.subTest(message=text):
                self.assertIn(text, source)
        self.assertIn("SYMBOL_VOLUME_MIN", source)
        self.assertIn("SYMBOL_VOLUME_STEP", source)
        self.assertIn("SYMBOL_FILLING_FOK | SYMBOL_FILLING_IOC", source)
        self.assertIn("SYMBOL_TRADE_STOPS_LEVEL", source)


if __name__ == "__main__":
    unittest.main()
