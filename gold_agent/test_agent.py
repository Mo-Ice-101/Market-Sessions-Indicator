import argparse
import json
import math
import sqlite3
import tempfile
import types
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

    def test_invented_reference_rejected(self):
        with patch.object(agent, "request", return_value=self.answer(
            news=[{"id": "invented", "mechanism": "x", "potential_impact": "supportive"}]
        )):
            self.assertEqual(agent.local_analysis("model", self.evidence())["status"], "error")

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
