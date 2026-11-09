import json
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import launcher


class LauncherTests(unittest.TestCase):
    def settings(self):
        return {"usd_symbol": "EURUSD_i", "usd_inverse": True, "model": "qwen2.5:7b"}

    def test_gold_symbol_matches_broker(self):
        self.assertEqual(launcher.GOLD_SYMBOL, "XAUUSD_r")

    def test_terminal_path_matches_requested_installation(self):
        self.assertEqual(str(launcher.MT5_PATH),
                         r"C:\Program Files\Weltrade MT5 Demo\terminal64.exe")

    def test_valid_settings(self):
        self.assertEqual(launcher.validate_settings(self.settings()), self.settings())

    def test_invalid_settings_rejected(self):
        for field, value in (("usd_symbol", "XAUUSD_r"), ("usd_symbol", ""),
                             ("usd_inverse", "false"), ("model", "-invalid"),
                             ("model", "something:cloud")):
            settings = self.settings()
            settings[field] = value
            with self.assertRaises(ValueError):
                launcher.validate_settings(settings)

    def test_first_run_requires_exact_symbol_and_orientation(self):
        mt5 = types.SimpleNamespace(symbols_get=lambda: [
            types.SimpleNamespace(name="EURUSD_i"), types.SimpleNamespace(name="XAUUSD_r")
        ])
        with tempfile.TemporaryDirectory() as folder, \
                patch("builtins.input", side_effect=["unknown", "EURUSD_i", "bad", "2", ""]):
            result = launcher.configure(mt5, Path(folder) / "startup.json")
        self.assertEqual(result, self.settings())

    def test_saved_settings_do_not_prompt(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "startup.json"
            path.write_text(json.dumps(self.settings()))
            with patch("builtins.input", side_effect=AssertionError("should not prompt")):
                self.assertEqual(launcher.configure(None, path), self.settings())

    def test_model_tag_matching(self):
        self.assertTrue(launcher.model_available("model", ["model:latest"]))
        self.assertTrue(launcher.model_available("model:7b", ["model:7b"]))
        self.assertFalse(launcher.model_available("model:7b", ["model:latest"]))

    def test_existing_ollama_is_reused(self):
        with patch.object(launcher, "ollama_models", return_value=["model:latest"]), \
                patch.object(launcher.subprocess, "Popen") as start:
            self.assertEqual(launcher.start_ollama(None, None, []), ["model:latest"])
            start.assert_not_called()

    def test_missing_ollama_has_actionable_error(self):
        with patch.object(launcher, "ollama_models", side_effect=OSError("offline")):
            with self.assertRaisesRegex(RuntimeError, "Install it"):
                launcher.start_ollama(None, None, [])

    def test_non_windows_fails_explicitly(self):
        with patch.object(launcher.sys, "platform", "linux"):
            with self.assertRaisesRegex(RuntimeError, "requires Windows"):
                launcher.run()


if __name__ == "__main__":
    unittest.main()
