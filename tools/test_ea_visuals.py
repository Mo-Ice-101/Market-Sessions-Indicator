"""EA-only wiring and portable execution of the actual MQL confirmation/view logic.

The C++ shim replaces terminal data/drawing APIs, not strategy functions.
Native MetaEditor compilation and visual-tester checks are still required.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "Market_Sessions_EA.mq5").read_text()
VISUALS = (ROOT / "Market_Sessions_EA_Visuals.mqh").read_text()
CORE = (ROOT / "Market_Sessions_Core.mqh").read_text()


def function(source, name):
    start = re.search(rf"(?:bool|void|int)\s+{name}\(", source).start()
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


class EAVisualWiringTests(unittest.TestCase):
    def test_no_external_boxes_dependency_or_duplicate_inputs(self):
        self.assertNotIn("iCustom(", EA)
        self.assertNotIn("tester_indicator", EA)
        self.assertNotIn("ChartIndicatorAdd", EA)
        self.assertNotIn("input ", VISUALS)
        self.assertNotIn("SessionUTC(", VISUALS)
        self.assertNotIn("EAServerTime(", VISUALS)
        self.assertIn('#include "Market_Sessions_EA_Visuals.mqh"', EA)
        self.assertIn("EASessionRange range = g_ranges[i];", VISUALS)
        self.assertIn("ReadRangeBreak(range, now, rates, confirmation, direction)", VISUALS)

    def test_visuals_do_not_consume_signals_or_place_orders(self):
        update = function(VISUALS, "UpdateEAVisuals")
        for forbidden in ("g_ranges[i].evaluated =", "EnterTrades(", "g_trade.",
                          "g_start_bar =", "g_last_signal_bar ="):
            self.assertNotIn(forbidden, update)
        for name in ("ProcessSignals", "ProcessMidpointTriggers", "ProcessM15Reversals"):
            self.assertIn("!g_sessions[g_ranges[i].session].enabled", function(EA, name))
        self.assertNotIn("!g_sessions[s].enabled", function(EA, "RebuildRanges"))
        self.assertIn("input bool InpTradeNY = false;", EA)

    def test_lifecycle_and_legacy_migration(self):
        self.assertIn("InitEAVisuals()", function(EA, "OnInit"))
        self.assertIn("DestroyEAVisuals()", function(EA, "OnDeinit"))
        self.assertIn("UpdateEAVisuals(", function(EA, "OnTick"))
        self.assertIn("UpdateEAVisuals(", function(EA, "OnTimer"))
        self.assertIn("RenderEAVisualFills()", function(EA, "OnChartEvent"))
        init = function(VISUALS, "InitEAVisuals")
        self.assertIn('name != "Market Sessions Boxes"', init)
        self.assertIn('StringFind(name, "MSB EA ")', init)
        self.assertIn("ChartIndicatorDelete", init)
        self.assertIn("!MQLInfoInteger(MQL_VISUAL_MODE)", init)
        self.assertIn("g_ea_visual_prefix", function(VISUALS, "DestroyEAVisuals"))

    @unittest.skipUnless(shutil.which("g++"), "Portable MQL shim requires g++")
    def test_actual_mql_view_and_confirmation_logic(self):
        functions = "\n".join((
            function(CORE, "FindOpeningBreak"),
            function(EA, "ReadRangeBreak"),
            function(VISUALS, "UpdateEAVisuals"),
        ))
        functions = functions.replace("const MqlRates &rates[]",
                                      "const std::vector<MqlRates> &rates")
        functions = functions.replace("MqlRates &rates[]", "std::vector<MqlRates> &rates")
        functions = functions.replace("MqlRates rates[];", "std::vector<MqlRates> rates;")
        shim = r"""
#include <cassert>
#include <string>
#include <vector>
using datetime = long long;
using ENUM_TIMEFRAMES = int;
using color = int;
constexpr int PERIOD_M5=5, PERIOD_M15=15, clrGray=0, clrGreen=1, clrRed=-1;
constexpr int SERIES_SYNCHRONIZED=1, SERIES_FIRSTDATE=2;
std::string _Symbol="gold";
struct MqlRates { datetime time; double high, low, close; };
struct EASessionRange {
  int session; datetime start, end, next_session; double high, low;
  bool loaded=false, evaluated=false;
};
struct Session { ENUM_TIMEFRAMES break_timeframe; bool enabled; };
struct View { datetime start, end; double high, low; color shade; };
Session g_sessions[3]={{5,true},{15,true},{5,false}};
std::vector<EASessionRange> g_ranges;
std::vector<View> g_ea_box_views;
std::vector<MqlRates> m5, m15;
bool g_ea_visuals_ready=true, history_ready=true;
datetime g_ea_visual_update=0, g_ea_visual_day=0, g_day=1;
std::string g_ea_visual_prefix="test";
int warnings=0;
int PeriodSeconds(int tf) { return tf*60; }
template<class T> int ArraySize(const std::vector<T>& v) { return v.size(); }
template<class T> int ArrayResize(std::vector<T>& v, int n) { v.resize(n); return n; }
bool RebuildRanges(datetime now) { return true; }
void ObjectsDeleteAll(int chart, std::string prefix) {}
void WarnEAVisual(std::string text) { warnings++; }
void DrawEAVisualStatus() {}
void RenderEAVisualFills() {}
void DrawEABox(const EASessionRange&, datetime, color, datetime, int) {}
bool LoadOpeningRange(std::string, datetime start, datetime now, double &high, double &low) {
  if(now<start+900 || !history_ready) return false;
  high=100; low=90; return true;
}
long SeriesInfoInteger(std::string, int, int what) {
  return what==SERIES_SYNCHRONIZED ? history_ready : 0;
}
int CopyRates(std::string, int tf, datetime start, datetime end, std::vector<MqlRates>& out) {
  out.clear();
  for(auto bar : tf==PERIOD_M5 ? m5 : m15)
    if(bar.time>=start && bar.time<=end) out.push_back(bar);
  return out.size();
}
"""
        checks = r"""
int main() {
  const datetime open=11*3600;
  g_ranges={{1,open,open+900,open+4*3600,0,0}};
  m5={{open+900,99,88,89}};
  m15={{open+900,101,88,95},{open+1800,102,94,101}};
  UpdateEAVisuals(open+899);
  assert(g_ea_box_views.empty());
  UpdateEAVisuals(open+900);
  assert(g_ea_box_views.size()==1 && g_ea_box_views[0].shade==clrGray);
  UpdateEAVisuals(open+1200);
  assert(g_ea_box_views[0].shade==clrGray); // M5 break cannot color London M15.
  UpdateEAVisuals(open+1800);
  assert(g_ea_box_views[0].shade==clrGray); // Wick outside; M15 close inside.
  UpdateEAVisuals(open+2699);
  assert(g_ea_box_views[0].shade==clrGray); // Forming M15 is never confirmation.
  UpdateEAVisuals(open+2704);
  assert(g_ea_box_views[0].shade==clrGreen);
  assert(g_ea_box_views[0].end==open+2700);
  assert(!g_ranges[0].evaluated && !g_ranges[0].loaded); // View is read-only.
  g_sessions[1].break_timeframe=PERIOD_M5;
  g_ea_visual_update=0;
  UpdateEAVisuals(open+1200);
  assert(g_ea_box_views[0].shade==clrRed && g_ea_box_views[0].end==open+1200);
  g_sessions[1].break_timeframe=PERIOD_M15;
  m15[0].close=100; m15[1].close=90;
  g_ea_visual_update=0;
  UpdateEAVisuals(open+2700);
  assert(g_ea_box_views[0].shade==clrGray); // Equality is not a break.
  m15[1].close=101;
  g_ranges[0].next_session=open+2700;
  g_ea_visual_update=0;
  UpdateEAVisuals(open+2700);
  assert(g_ea_box_views[0].shade==clrGray); // Next-open boundary excluded.
  g_ranges[0].session=2;
  g_ranges[0].next_session=open+4*3600;
  g_ea_visual_update=0;
  UpdateEAVisuals(open+1200);
  assert(g_ea_box_views[0].shade==clrRed && !g_sessions[2].enabled);
  history_ready=false;
  g_ea_visual_update=0;
  UpdateEAVisuals(open+1200);
  assert(g_ea_box_views.empty() && warnings>0);
  history_ready=true;
  UpdateEAVisuals(open+1205);
  assert(g_ea_box_views.size()==1 && g_ea_box_views[0].shade==clrRed);
  g_ea_visuals_ready=false;
  g_ea_box_views.clear();
  UpdateEAVisuals(open+1500);
  assert(g_ea_box_views.empty());
}
"""
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "visuals.cpp"
            binary = Path(folder) / "visuals"
            source.write_text(shim + functions + checks)
            compile_result = subprocess.run(
                ["g++", "-std=c++17", str(source), "-o", str(binary)],
                capture_output=True, text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
