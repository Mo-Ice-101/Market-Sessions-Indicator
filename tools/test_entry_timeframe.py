"""Verify selectable entry confirmation using synthetic, fully populated M1 bars."""
import csv
import datetime as dt
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class EntryTimeframeTests(unittest.TestCase):
    def replay(self, minutes, extra=()):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "bars.csv"
            with path.open("w", newline="") as output:
                writer = csv.writer(output, delimiter="\t")
                writer.writerow(["<DATE>", "<TIME>", "<OPEN>", "<HIGH>", "<LOW>",
                                 "<CLOSE>", "<TICKVOL>", "<VOL>", "<SPREAD>"])
                start = dt.datetime(2026, 1, 13, 0)
                for index in range(120):
                    stamp = start + dt.timedelta(minutes=index)
                    close = 101 if stamp >= start + dt.timedelta(minutes=75) else 100
                    writer.writerow([stamp.strftime("%Y.%m.%d"), stamp.strftime("%H:%M:%S"),
                                     close, close + 0.1, close - 0.1, close, 1, 0, 0])
            env = {key: value for key, value in os.environ.items() if key not in {
                "SKIP", "NOMID", "BE_R", "REVERSAL", "NY_SWEEP", "FIXRR", "HALF_AT_BE",
                "UNLOCK", "SCALE_FRACTION",
            }}
            return subprocess.run(
                [sys.executable, str(ROOT / "tools/sim_ea.py"), str(path),
                 "--entry-minutes", str(minutes), "--verbose", *extra],
                env=env, capture_output=True, text=True, check=True,
            ).stdout

    def test_m5_enters_after_first_five_minute_breakout(self):
        output = self.replay(5)
        self.assertIn("Entry confirmation=M5; opening range=M15", output)
        self.assertIn("2026-01-13 01:20:00 Asian", output)

    def test_m15_waits_for_fifteen_minute_breakout(self):
        output = self.replay(15)
        self.assertIn("Entry confirmation=M15; opening range=M15", output)
        self.assertIn("2026-01-13 01:30:00 Asian", output)
        self.assertNotIn("2026-01-13 01:20:00 Asian", output)

    def test_session_override_does_not_change_other_sessions(self):
        output = self.replay(5, ("--asian-entry-minutes", "15"))
        self.assertIn("2026-01-13 01:30:00 Asian", output)
        self.assertIn("'Asian': 15, 'London': 5, 'NY': 5", output)

    def test_london_override_preserves_asian_m5(self):
        output = self.replay(5, ("--london-entry-minutes", "15"))
        self.assertIn("2026-01-13 01:20:00 Asian", output)
        self.assertIn("'Asian': 5, 'London': 15, 'NY': 5", output)

    def test_ea_and_visuals_share_session_timeframes(self):
        ea = (ROOT / "Market_Sessions_EA.mq5").read_text()
        visuals = (ROOT / "Market_Sessions_EA_Visuals.mqh").read_text()
        for session in ("Asian", "London", "NY"):
            self.assertIn(
                f"input BreakEntryTimeframe Inp{session}BreakEntryTF = BREAK_ENTRY_M5;", ea
            )
        self.assertIn("input bool InpTradeNY = false;", ea)
        self.assertIn('g_sessions[range.session].break_timeframe', visuals)
        self.assertIn("ReadRangeBreak(range, now, rates, confirmation, direction)", visuals)
        self.assertIn("ReadRangeBreak(g_ranges[i], signal_bar, rates, confirmation, direction)", ea)
        self.assertIn("confirmation + seconds > g_start_bar", ea)
        self.assertIn("tick.time < signal_bar + PeriodSeconds(PERIOD_M5)", ea)


if __name__ == "__main__":
    unittest.main()
