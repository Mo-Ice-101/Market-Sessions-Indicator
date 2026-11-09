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
    def replay(self, minutes):
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
                 "--entry-minutes", str(minutes), "--verbose"],
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


if __name__ == "__main__":
    unittest.main()
