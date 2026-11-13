"""Execute the actual EA management routine with mocked terminal/broker APIs."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_ea_visuals import function


ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "Market_Sessions_EA.mq5").read_text()


class ScaleOutRRTests(unittest.TestCase):
    def test_inputs_persistence_and_independent_trailing(self):
        self.assertIn("input ScaleOutRR InpScaleOutRR = SCALE_OUT_2R;", EA)
        self.assertIn("InpScaleOutRR < SCALE_OUT_1R || InpScaleOutRR > SCALE_OUT_3R", EA)
        arm = function(EA, "ArmScaleOut")
        self.assertIn('const string trigger = "2R"', arm)  # Existing live 2R keys preserved.
        self.assertIn("g_triggers[i].key == key", arm)
        self.assertIn("if(!tester)", arm)
        self.assertIn("GlobalVariablesFlush()", arm)
        self.assertIn('if(!tester && !g_triggers[index].armed', arm)
        management = function(EA, "ManagePositions")
        self.assertIn("if(trail_armed && ReadATR(atr))", management)
        self.assertNotIn("if(scale_complete && ReadATR(atr))", management)
        self.assertIn("GlobalVariableDel(key)", management)

    @unittest.skipUnless(shutil.which("g++"), "Portable MQL shim requires g++")
    def test_actual_ea_management_at_each_selected_rr(self):
        source = function(EA, "ManagePositions").replace(
            "MqlRates completed[];", "std::vector<MqlRates> completed;"
        )
        shim = r"""
#include <cassert>
#include <cmath>
#include <map>
#include <string>
#include <vector>
#include <algorithm>
using string=std::string; using datetime=long long;
constexpr int SCALE_OUT_1R=1,SCALE_OUT_2R=2,SCALE_OUT_3R=3;
constexpr int POSITION_SYMBOL=1,POSITION_MAGIC=2,POSITION_TYPE=3,POSITION_IDENTIFIER=4,
POSITION_VOLUME=5,POSITION_SL=6,POSITION_TP=7,POSITION_TIME=8,POSITION_TYPE_BUY=0,
SYMBOL_VOLUME_STEP=10,SYMBOL_VOLUME_MIN=11,SYMBOL_TRADE_TICK_SIZE=12,
SYMBOL_TRADE_STOPS_LEVEL=13,SYMBOL_TRADE_FREEZE_LEVEL=14,PERIOD_M1=1,MQL_TESTER=1;
struct MqlTick { double bid,ask; };
struct MqlRates { datetime time; double close; int spread; };
struct Trigger { ulong identifier; string key; };
std::vector<Trigger> g_triggers;
string _Symbol="gold"; ulong InpMagic=123;
int InpScaleOutRR=2; double InpBreakEvenR=1,InpTrailingATR=2,_Point=.001;
bool buy=true,allowed=true,fail_close=false,fail_modify=false,history=true,m1_ready=true;
double volume=.04,scaled=0,sl=90,closed=110; int close_count=0,modify_count=0,atr_reads=0;
std::map<string,bool> markers;
int PositionsTotal(){return 1;}
ulong PositionGetTicket(int){return 1;}
string PositionGetString(int){return _Symbol;}
long PositionGetInteger(int key){
 if(key==POSITION_MAGIC) return InpMagic;
 if(key==POSITION_TYPE) return buy ? POSITION_TYPE_BUY : 1;
 if(key==POSITION_IDENTIFIER) return 1;
 return 0;
}
double PositionGetDouble(int key){
 if(key==POSITION_VOLUME)return volume;
 if(key==POSITION_SL)return sl;
 return 0;
}
bool PositionSelectByTicket(ulong){return true;}
bool HasPendingEAOrder(){return false;}
void Warn(string){}
bool PositionHistory(ulong,bool,double &entry,double &risk,double &original,double &done){
 entry=100; risk=10; original=.04; done=scaled; return history;
}
double SymbolInfoDouble(string,int key){return key==SYMBOL_TRADE_TICK_SIZE?.001:.01;}
long SymbolInfoInteger(string,int){return 0;}
double MathAbs(double x){return std::abs(x);}
double MathMax(double a,double b){return std::max(a,b);}
double MathMin(double a,double b){return std::min(a,b);}
double FloorVolume(double x,double step){return std::floor(x/step+1e-8)*step;}
bool ArmScaleOut(ulong,bool reached,string key="2R"){
 markers[key]=markers[key]||reached; return markers[key];
}
int CopyRates(string,int,int,int,std::vector<MqlRates>& out){
 out={{100,closed,0}}; return m1_ready?1:0;
}
int PeriodSeconds(int){return 60;}
string IntegerToString(int x){return std::to_string(x);}
bool TradingAllowed(){return allowed;}
bool ClosePartial(ulong,bool,double amount,const MqlTick&){
 close_count++; if(fail_close)return false;
 volume-=amount; scaled+=amount; return true;
}
double StopPrice(double x,double,bool){return x;}
bool ReadATR(double &a){atr_reads++;a=1;return true;}
struct Trade {
 bool PositionModify(ulong,double stop,double){
   modify_count++; if(fail_modify)return false;sl=stop;return true;
 }
} g_trade;
bool TradeResult(bool success,string){return success;}
template<class T>int ArraySize(const std::vector<T>& x){return x.size();}
template<class T>int ArrayResize(std::vector<T>& x,int n){x.resize(n);return n;}
bool MQLInfoInteger(int){return true;}
bool GlobalVariableCheck(string){return false;}
bool GlobalVariableDel(string){return true;}
void reset(int rr,bool is_buy=true){
 InpScaleOutRR=rr;buy=is_buy;volume=.04;scaled=0;sl=buy?90:110;
 markers.clear();g_triggers.clear();close_count=modify_count=atr_reads=0;
 allowed=history=m1_ready=true;fail_close=fail_modify=false;InpBreakEvenR=1;
}
void check(double value,double expected){assert(std::abs(value-expected)<1e-7);}
"""
        checks = r"""
int main(){
 reset(1);closed=109;
 ManagePositions({110,110}); check(volume,.04);check(sl,90); // wick insufficient
 closed=110;ManagePositions({110,110});check(volume,.02);check(sl,100);assert(atr_reads==0);
 ManagePositions({119,119});check(sl,100);assert(close_count==1&&atr_reads==0);
 ManagePositions({120,120});check(sl,118);assert(close_count==1&&atr_reads==1);
 ManagePositions({119,119});check(sl,118); // latch survives pullback; never loosen

 reset(2);closed=110;ManagePositions({110,110});check(volume,.04);check(sl,100);
 ManagePositions({120,120});check(volume,.02);check(sl,118);assert(close_count==1);
 ManagePositions({121,121});check(volume,.02);assert(close_count==1);

 reset(3);closed=110;ManagePositions({110,110});check(volume,.04);check(sl,100);
 ManagePositions({120,120});check(volume,.04);check(sl,118); // trail before 3R half
 ManagePositions({130,130});check(volume,.02);check(sl,128);assert(close_count==1);

 reset(1,false);closed=90;ManagePositions({90,90});check(volume,.02);check(sl,100);
 ManagePositions({80,80});check(sl,82);
 reset(3,false);closed=90;ManagePositions({90,90});check(sl,100);
 ManagePositions({80,80});check(volume,.04);check(sl,82);
 ManagePositions({70,70});check(volume,.02);check(sl,72);

 reset(1);closed=110;fail_close=true;
 ManagePositions({110,110});check(volume,.04);
 fail_close=false;closed=109;ManagePositions({109,109}); // retry latched 1R close
 check(volume,.02);check(sl,100);assert(close_count==2);

 reset(2);closed=110;fail_close=true;ManagePositions({120,120});
 fail_close=false;ManagePositions({119,119});check(volume,.02);check(sl,117);

 reset(1);closed=110;fail_modify=true;ManagePositions({110,110});check(sl,90);
 fail_modify=false;closed=109;ManagePositions({109,109});check(sl,100);assert(close_count==1);

 reset(1);closed=110;m1_ready=false;ManagePositions({110,110});check(volume,.04);check(sl,90);
 reset(2);closed=110;allowed=false;ManagePositions({120,120});check(volume,.04);check(sl,90);
 reset(2);history=false;ManagePositions({120,120});assert(close_count==0&&modify_count==0);
 reset(1);closed=110;scaled=.02;volume=.02;ManagePositions({110,110});
 check(sl,100);assert(close_count==0&&atr_reads==0); // recover existing half from history
 reset(3);closed=110;scaled=.02;volume=.02;ManagePositions({125,125});
 check(sl,123);assert(close_count==0); // recovered 3R half implies prior 2R
}
"""
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / "manage.cpp").write_text(shim + source + checks)
            result = subprocess.run(
                ["g++", "-std=c++17", str(path / "manage.cpp"), "-o", str(path / "manage")],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(path / "manage")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
