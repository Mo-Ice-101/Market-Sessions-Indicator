import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch


@unittest.skipUnless(importlib.util.find_spec("streamlit"), "Dashboard dependency is not installed")
class DashboardTests(unittest.TestCase):
    def test_forecast_explanation_and_source_warnings_render(self):
        from streamlit.testing.v1 import AppTest

        report = {
            "status": "degraded", "market": {"status": "ok"},
            "real_yields": {"status": "ok"},
            "source_health": {"GDELT": {"status": "error"}}, "news": [],
            "ai": {
                "status": "ok", "model": "local-model",
                "result": {
                    "assessment": "mixed", "confidence": "low",
                    "summary": "No defensible direction.",
                    "reasons": ["Correlation is weak."],
                    "opposing_evidence": ["News retrieval is incomplete."],
                    "invalidation": "Fresh corroborating evidence could change this view.",
                    "news": [], "caveats": [],
                },
            },
        }
        original = Path.read_text

        def read(path, *args, **kwargs):
            return json.dumps(report) if path.name == "latest.json" else original(path, *args, **kwargs)

        with patch.object(Path, "read_text", read):
            app = AppTest.from_file(str(Path(__file__).with_name("app.py"))).run(timeout=30)
        self.assertFalse(app.exception)
        markdown = "\n".join(item.value for item in app.markdown)
        headings = [item.value for item in app.subheader]
        self.assertIn("No clear UP / DOWN direction", markdown)
        self.assertIn("What the AI predicts and why", headings)
        self.assertIn("Observed market moves — NOT predictions", headings)
        self.assertIn("Fresh corroborating evidence", markdown)
        self.assertTrue(any("Missing headlines do not mean" in item.value for item in app.warning))


if __name__ == "__main__":
    unittest.main()
