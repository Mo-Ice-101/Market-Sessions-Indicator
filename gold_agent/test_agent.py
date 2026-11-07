import argparse
import json
import math
import sqlite3
import tempfile
import types
import urllib.error
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

import agent


NOW = datetime(2026, 11, 6, 15, 0, tzinfo=agent.UTC)


def prices(count=310, same=False):
    start = int(NOW.timestamp()) - count * 300
    gold, dollar = {}, {}
    g, d = 2000.0, 100.0
    for i in range(count):
        change = (1 + i % 7) * 0.0001
        g *= math.exp(change)
        d *= math.exp(change if same else -change)
        gold[start + i * 300] = g
        dollar[start + i * 300] = d
    return gold, dollar


class MarketTests(unittest.TestCase):
    def test_ea_asian_window_waits_for_m15_then_ends_at_london(self):
        wait = agent.trading_session(datetime(2026, 1, 13, 23, 10, tzinfo=agent.UTC))
        self.assertEqual(wait["session"], "Asian")
        self.assertFalse(wait["active"])
        self.assertIn("M15", wait["reason"])
        active = agent.trading_session(datetime(2026, 1, 13, 23, 20, tzinfo=agent.UTC))
        self.assertTrue(active["active"])
        self.assertEqual(active["next_session_open_utc"], "2026-01-14T09:00:00+00:00")

    def test_ea_london_and_disabled_new_york_windows_in_winter(self):
        london = agent.trading_session(datetime(2026, 1, 13, 9, 20, tzinfo=agent.UTC))
        self.assertTrue(london["active"])
        self.assertEqual(london["session"], "London")
        self.assertEqual(london["next_session_open_utc"], "2026-01-13T13:30:00+00:00")
        ny = agent.trading_session(datetime(2026, 1, 13, 13, 50, tzinfo=agent.UTC))
        self.assertEqual(ny["session"], "New York")
        self.assertFalse(ny["active"])
        self.assertIn("disabled", ny["reason"])

    def test_ea_london_and_new_york_opens_follow_daylight_saving(self):
        london = agent.trading_session(datetime(2026, 7, 1, 8, 20, tzinfo=agent.UTC))
        self.assertTrue(london["active"])
        self.assertEqual(london["next_session_open_utc"], "2026-07-01T12:30:00+00:00")
        ny = agent.trading_session(datetime(2026, 7, 1, 12, 50, tzinfo=agent.UTC))
        self.assertFalse(ny["active"])
        self.assertEqual(ny["session"], "New York")

    def test_inverse_returns(self):
        context = agent.market_context(*prices(), NOW.timestamp())
        self.assertEqual(context["status"], "ok")
        self.assertEqual(context["relationship"], "inverse")
        self.assertAlmostEqual(context["windows_m5_returns"]["288"]["correlation"], -1)
        self.assertEqual(context["recent_move"], "opposite_direction")

    def test_same_direction_is_not_forced_inverse(self):
        context = agent.market_context(*prices(same=True), NOW.timestamp())
        self.assertEqual(context["relationship"], "positive")
        self.assertEqual(context["recent_move"], "same_direction")

    def test_fx_proxy_is_inverted_and_labeled(self):
        context = agent.market_context(*prices(same=True), NOW.timestamp(), inverse=True)
        self.assertEqual(context["relationship"], "inverse")
        self.assertIn("proxy, not DXY", context["usd_measure"])

    def test_short_history_has_no_window_correlation(self):
        context = agent.market_context(*prices(20), NOW.timestamp())
        self.assertIsNone(context["windows_m5_returns"]["36"]["correlation"])
        self.assertEqual(context["relationship"], "insufficient_history")

    def test_missing_bars_do_not_bridge_gap(self):
        g, d = prices(40)
        del d[sorted(d)[20]]
        context = agent.market_context(g, d, NOW.timestamp())
        self.assertEqual(context["windows_m5_returns"]["36"]["samples"], 36)
        # Total of 37 usable returns: the two adjacent intervals are excluded.
        self.assertEqual(context["windows_m5_returns"]["288"]["samples"], 37)

    def test_incomplete_latest_hour(self):
        g, d = prices()
        del d[sorted(d)[-4]]
        context = agent.market_context(g, d, NOW.timestamp())
        self.assertEqual(context["recent_move"], "incomplete_window")

    def test_stale_weekend(self):
        context = agent.market_context(*prices(), (NOW + timedelta(days=2)).timestamp())
        self.assertEqual(context["status"], "stale")

    def test_constant_returns_have_no_correlation(self):
        self.assertIsNone(agent.correlation([0, 0, 0], [1, 2, 3]))

    def test_empty_alignment_is_explicit_error(self):
        with self.assertRaisesRegex(ValueError, "No matching"):
            agent.market_context({}, {}, NOW.timestamp())

    def test_inverse_regime_can_weaken(self):
        g, d = prices()
        keys = sorted(d)
        for i in range(len(keys) - 36, len(keys)):
            d[keys[i]] = d[keys[i - 1]] * g[keys[i]] / g[keys[i - 1]]
        context = agent.market_context(g, d, NOW.timestamp())
        self.assertEqual(context["relationship"], "positive")
        self.assertEqual(context["relationship_change"], "inverse_relationship_weakened")


class NewsTests(unittest.TestCase):
    def test_gdelt_rate_limit_cooldown_preserves_other_feeds(self):
        rate_error = urllib.error.HTTPError(
            "https://api.gdeltproject.org", 429, "Too Many Requests",
            {"Retry-After": "3600"}, None,
        )
        calls = []

        def retrieve(url):
            calls.append(url)
            if "api.gdeltproject.org" in url:
                raise rate_error
            return b"<rss><channel/></rss>"

        with patch.object(agent, "GDELT_RETRY_AT", None), \
                patch.object(agent, "GDELT_RATE_FAILURES", 0), \
                patch.object(agent, "request", side_effect=retrieve):
            _, first = agent.collect_news(NOW, 24)
            self.assertEqual(agent.GDELT_RETRY_AT, NOW + timedelta(hours=1))
            _, second = agent.collect_news(NOW + timedelta(minutes=15), 24)
            self.assertIn("cooldown", second["GDELT"]["error"])
            self.assertEqual(sum("api.gdeltproject.org" in url for url in calls), 1)
            self.assertEqual(len(calls), 9)
            self.assertEqual(first["Federal Reserve"]["status"], "ok")

    def test_treasury_fallback_is_attributed(self):
        xml = b"""<feed xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata"
        xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices">
        <m:properties><d:NEW_DATE>2026-11-05T00:00:00</d:NEW_DATE>
        <d:TC_10YEAR>1.80</d:TC_10YEAR></m:properties>
        <m:properties><d:NEW_DATE>2026-11-06T00:00:00</d:NEW_DATE>
        <d:TC_10YEAR>1.85</d:TC_10YEAR></m:properties></feed>"""
        with patch.object(agent, "request", side_effect=[
            urllib.error.HTTPError("url", 404, "Not Found", {}, None), xml
        ]) as retrieve:
            result = agent.real_yields(NOW)
        self.assertEqual(result["status"], "ok")
        self.assertIn("Treasury", result["series"])
        self.assertIn("404", result["source_warning"])
        self.assertAlmostEqual(result["change_basis_points"], 5)
        self.assertIn("daily_treasury_real_yield_curve", retrieve.call_args.args[0])

    def test_both_yield_sources_fail_explicitly(self):
        with patch.object(agent, "request", side_effect=OSError("offline")):
            result = agent.real_yields(NOW)
        self.assertEqual(result["status"], "error")
        self.assertIn("FRED", result["error"])
        self.assertIn("Treasury", result["error"])

    def test_non_feed_response_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "neither an RSS"):
            agent.read_feed("test", b"<html><body>Unavailable</body></html>", NOW, 24)

    def test_rss_freshness_and_topics(self):
        xml = b"""<rss><channel>
        <item><title>Inflation and gold</title><link>https://example.org/a</link>
        <pubDate>Fri, 06 Nov 2026 14:00:00 GMT</pubDate></item>
        <item><title>Old</title><link>https://example.org/b</link>
        <pubDate>Mon, 02 Nov 2026 14:00:00 GMT</pubDate></item>
        <item><title>Missing date</title><link>https://example.org/c</link></item>
        </channel></rss>"""
        result = agent.read_feed("test", xml, NOW, 24)
        self.assertEqual(len(result), 1)
        self.assertIn("inflation", result[0]["topics"])
        self.assertIn("gold_flows_supply", result[0]["topics"])

    def test_atom_supported(self):
        xml = b"""<feed xmlns="http://www.w3.org/2005/Atom"><entry>
        <title>Fed rate decision</title><link href="https://example.org/a"/>
        <updated>2026-11-06T14:00:00Z</updated></entry></feed>"""
        self.assertEqual(len(agent.read_feed("test", xml, NOW, 24)), 1)

    def test_future_undated_and_unsafe_links_rejected(self):
        for date, url in (("2026-11-07T00:00:00Z", "https://example.org"),
                          ("", "https://example.org"),
                          ("2026-11-06T14:00:00Z", "javascript:bad")):
            self.assertIsNone(agent.article("test", "gold", url, date, NOW, 24))

    def test_failed_source_is_not_silent_empty_success(self):
        with patch.object(agent, "request", side_effect=OSError("offline")):
            items, health = agent.collect_news(NOW, 24)
        self.assertEqual(items, [])
        self.assertTrue(all(item["status"] == "error" for item in health.values()))

    def test_yields_parse_missing_values_and_basis_points(self):
        csv = b"observation_date,DFII10\n2026-11-04,1.80\n2026-11-05,.\n2026-11-06,1.85\n"
        with patch.object(agent, "request", return_value=csv):
            result = agent.real_yields(NOW)
        self.assertEqual(result["status"], "ok")
        self.assertAlmostEqual(result["change_basis_points"], 5)

    def test_yields_stale_and_invalid(self):
        with patch.object(agent, "request", return_value=b"DATE,DFII10\n2026-10-01,1\n2026-10-02,2\n"):
            self.assertEqual(agent.real_yields(NOW)["status"], "stale")
        with patch.object(agent, "request", return_value=b"DATE,DFII10\n2026-11-05,1\n2026-11-06,nan\n"):
            self.assertEqual(agent.real_yields(NOW)["status"], "error")


class AITests(unittest.TestCase):
    def evidence(self, status="ok"):
        return {"market": {"status": status}, "news": [{"id": "known"}]}

    def answer(self, **kwargs):
        result = {"assessment": "mixed", "confidence": "low", "summary": "Conflicting signals",
                  "caveats": [], "news": [{"id": "known", "mechanism": "Possible safe-haven demand",
                                          "potential_impact": "unclear"}]}
        result.update(kwargs)
        return json.dumps({"response": json.dumps(result)}).encode()

    def test_local_only_and_valid_answer(self):
        with patch.object(agent, "request", return_value=self.answer()) as req:
            result = agent.local_analysis("local-model", self.evidence())
        self.assertEqual(result["status"], "ok")
        self.assertEqual(req.call_args.args[0], "http://127.0.0.1:11434/api/generate")
        self.assertEqual(req.call_args.args[1]["options"]["num_predict"], 1200)

    def test_local_inference_gets_longer_timeout(self):
        from unittest.mock import MagicMock
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b"{}"
        with patch.object(agent.urllib.request, "urlopen", return_value=response) as connect:
            agent.request("http://127.0.0.1:11434/api/generate", {"model": "model"})
        self.assertEqual(connect.call_args.kwargs["timeout"], 600)

    def test_invented_reference_rejected(self):
        with patch.object(agent, "request", return_value=self.answer(
            news=[{"id": "invented", "mechanism": "x", "potential_impact": "supportive"}]
        )):
            result = agent.local_analysis("model", self.evidence())
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["result"]["assessment"], "insufficient_evidence")
        self.assertEqual(result["result"]["news"], [])

    def test_invalid_schema_rejected(self):
        with patch.object(agent, "request", return_value=self.answer(caveats="not a list")):
            self.assertEqual(agent.local_analysis("model", self.evidence())["status"], "error")

    def test_stale_market_cannot_produce_directional_assessment(self):
        with patch.object(agent, "request", return_value=self.answer(
            assessment="supportive", confidence="high"
        )):
            result = agent.local_analysis("model", self.evidence("stale"))
        self.assertEqual(result["result"]["assessment"], "insufficient_evidence")
        self.assertEqual(result["result"]["confidence"], "low")

    def test_disabled_ai_is_labeled(self):
        self.assertEqual(agent.local_analysis(None, self.evidence())["status"], "disabled")


class MT5Tests(unittest.TestCase):
    def module(self):
        module = types.SimpleNamespace(
            TIMEFRAME_M5=5, initialize=lambda: True, shutdown=lambda: None,
            symbol_select=lambda *_: True, last_error=lambda: (1, "error"),
        )
        return module

    def test_adapter_uses_completed_bars_and_shuts_down(self):
        module = self.module()
        g, d = prices()
        data = [g, d]
        calls, shutdown = [], []

        def rates(symbol, timeframe, start, count):
            calls.append((symbol, timeframe, start, count))
            bars = data[len(calls) - 1]
            return [{"time": t, "close": c} for t, c in bars.items()]

        module.copy_rates_from_pos = rates
        module.shutdown = lambda: shutdown.append(True)
        args = argparse.Namespace(gold_symbol="gold", usd_symbol="USD", usd_inverse=False,
                                  mt5_path=None)
        with patch.dict("sys.modules", {"MetaTrader5": module}):
            result = agent.read_market(args, NOW)
        self.assertEqual(result["relationship"], "inverse")
        self.assertEqual([call[2] for call in calls], [1, 1])
        self.assertEqual(shutdown, [True])

    def test_invalid_symbol_is_explicit_and_shuts_down(self):
        module = self.module()
        module.symbol_select = lambda *_: False
        shutdown = []
        module.shutdown = lambda: shutdown.append(True)
        args = argparse.Namespace(gold_symbol="missing", usd_symbol="USD", usd_inverse=False,
                                  mt5_path=None)
        with patch.dict("sys.modules", {"MetaTrader5": module}):
            with self.assertRaisesRegex(RuntimeError, "cannot select missing"):
                agent.read_market(args, NOW)
        self.assertEqual(shutdown, [True])

    def test_explicit_terminal_used_for_scan(self):
        module = self.module()
        from unittest.mock import Mock
        module.initialize = Mock(return_value=True)
        g, d = prices()
        bars = iter((g, d))
        module.copy_rates_from_pos = lambda *_: [
            {"time": stamp, "close": close} for stamp, close in next(bars).items()
        ]
        path = r"C:\Program Files\Weltrade MT5 Demo\terminal64.exe"
        args = argparse.Namespace(gold_symbol="gold", usd_symbol="USD", usd_inverse=False,
                                  mt5_path=path)
        with patch.dict("sys.modules", {"MetaTrader5": module}):
            agent.read_market(args, NOW)
        module.initialize.assert_called_once_with(path)


class PersistenceTests(unittest.TestCase):
    def test_forecast_is_saved_and_only_scored_after_one_hour(self):
        baseline_open = int(NOW.timestamp()) - 300
        evidence = {
            "market": {"status": "ok",
                       "latest_completed_bar_utc": datetime.fromtimestamp(
                           baseline_open, agent.UTC
                       ).isoformat()},
            "ai": {"status": "ok", "model": "local-model",
                   "result": {"assessment": "supportive", "confidence": "medium"}},
        }
        gold = [(baseline_open, 2000.0)]
        with sqlite3.connect(":memory:") as db:
            agent.initialize_forecasts(db)
            self.assertTrue(agent.record_forecast(db, evidence, gold, NOW, "Asian"))
            self.assertEqual(agent.grade_forecasts(db, gold, NOW), 0)
            # First five-minute candle close on or after the one-hour target.
            future_open = baseline_open + 3600
            future_gold = gold + [(future_open, 2010.0)]
            self.assertEqual(agent.grade_forecasts(
                db, future_gold, NOW + timedelta(hours=1, minutes=5)
            ), 1)
            row = db.execute(
                "SELECT direction, actual_return_percent, correct, session FROM forecasts"
            ).fetchone()
        self.assertEqual(row[0], "up")
        self.assertAlmostEqual(row[1], 0.5)
        self.assertEqual(row[2], 1)
        self.assertEqual(row[3], "Asian")

    def test_mixed_or_stale_ai_is_not_counted_as_directional_forecast(self):
        baseline_open = int(NOW.timestamp()) - 300
        evidence = {
            "market": {"status": "ok", "latest_completed_bar_utc":
                       datetime.fromtimestamp(baseline_open, agent.UTC).isoformat()},
            "ai": {"status": "ok", "result": {"assessment": "mixed", "confidence": "low"}},
        }
        with sqlite3.connect(":memory:") as db:
            agent.initialize_forecasts(db)
            self.assertFalse(agent.record_forecast(db, evidence, [(baseline_open, 2000)], NOW, "Asian"))
            evidence["ai"]["result"]["assessment"] = "pressuring"
            evidence["market"]["status"] = "stale"
            self.assertFalse(agent.record_forecast(db, evidence, [(baseline_open, 2000)], NOW, "Asian"))
            self.assertEqual(db.execute("SELECT count(*) FROM forecasts").fetchone()[0], 0)

    def test_forecast_during_closing_gap_expires_instead_of_scoring_weekend(self):
        baseline_open = int(NOW.timestamp()) - 300
        evidence = {
            "market": {"status": "ok", "latest_completed_bar_utc":
                       datetime.fromtimestamp(baseline_open, agent.UTC).isoformat()},
            "ai": {"status": "ok", "model": "local-model",
                   "result": {"assessment": "pressuring", "confidence": "medium"}},
        }
        with sqlite3.connect(":memory:") as db:
            agent.initialize_forecasts(db)
            self.assertTrue(agent.record_forecast(db, evidence, [(baseline_open, 2000)], NOW, "London"))
            late_open = baseline_open + 3600 + 900
            late = NOW + timedelta(hours=1, minutes=20)
            self.assertEqual(agent.grade_forecasts(db, [(late_open, 1990)], late), 0)
            status, correct, session = db.execute(
                "SELECT outcome_status, correct, session FROM forecasts"
            ).fetchone()
        self.assertEqual(status, "expired")
        self.assertIsNone(correct)
        self.assertEqual(session, "London")

    def test_old_forecast_database_migrates_in_place(self):
        with sqlite3.connect(":memory:") as db:
            db.execute(
                """CREATE TABLE forecasts (
                   id INTEGER PRIMARY KEY, created_utc TEXT NOT NULL, target_utc TEXT NOT NULL,
                   direction TEXT NOT NULL, confidence TEXT NOT NULL, model TEXT NOT NULL,
                   baseline_price REAL NOT NULL, target_price REAL, actual_return_percent REAL,
                   correct INTEGER, outcome_utc TEXT, scored_utc TEXT)"""
            )
            agent.initialize_forecasts(db)
            columns = {row[1] for row in db.execute("PRAGMA table_info(forecasts)")}
        self.assertIn("session", columns)
        self.assertIn("outcome_status", columns)

    def test_scan_reports_and_deduplication(self):
        with tempfile.TemporaryDirectory() as folder:
            args = argparse.Namespace(output=Path(folder), lookback_hours=24,
                                      max_headlines=1, ollama_model=None)
            stories = [
                agent.article("test", "gold news", f"https://example.org/{i}",
                              "2026-11-06T14:00:00Z", NOW, 24)
                for i in (1, 2)
            ]
            with patch.object(agent, "utc_now", return_value=NOW), \
                    patch.object(agent, "collect_news", side_effect=lambda *_: (
                        [dict(item) for item in stories], {"test": {"status": "ok"}}
                    )), patch.object(agent, "real_yields", return_value={"status": "ok"}), \
                    patch.object(agent, "read_market", return_value={"status": "ok"}):
                first = agent.scan(args)
                second = agent.scan(args)
            self.assertTrue(first["news"][0]["new"])
            self.assertFalse(second["news"][0]["new"])
            saved = json.loads((Path(folder) / "latest.json").read_text())
            self.assertEqual(saved["status"], "ok")
            with sqlite3.connect(Path(folder) / "state.sqlite3") as db:
                self.assertEqual(db.execute("SELECT count(*) FROM seen").fetchone()[0], 1)

    def test_degraded_scan_is_persisted(self):
        with tempfile.TemporaryDirectory() as folder:
            args = argparse.Namespace(output=Path(folder), lookback_hours=24,
                                      max_headlines=30, ollama_model="model")
            with patch.object(agent, "collect_news", return_value=([], {"test": {"status": "error"}})), \
                    patch.object(agent, "real_yields", return_value={"status": "error"}), \
                    patch.object(agent, "read_market", side_effect=RuntimeError("MT5 disconnected")), \
                    patch.object(agent, "local_analysis", return_value={"status": "error"}):
                result = agent.scan(args)
            self.assertEqual(result["status"], "degraded")
            self.assertTrue((Path(folder) / "latest.json").exists())


if __name__ == "__main__":
    unittest.main()
