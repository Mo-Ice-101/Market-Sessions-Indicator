#property strict
#property version "1.08"
#property description "Opening M15 / M5 breakout and midpoint entries, 50% at 2R, ATR trail."
#property tester_indicator "Market_Sessions_Boxes.ex5"

#include <Trade/Trade.mqh>
#include "Market_Sessions_Core.mqh"

input group "EA Control"
input bool InpEnableEA = true; // Enable new entries; existing positions remain managed
input bool InpShowSessionBoxes = true; // Automatically attach matching indicator on chart
input int  InpBoxTransparency = 85; // Fill transparency 0-100; borders/levels stay visible
input bool InpEnableM15Reversal = false; // 15M reversal strategy: one opposite entry after first closes, even after profit
input bool InpDebugSignals = true; // Explain session signals and entry decisions in Experts / tester Journal

enum PositionSizing
{
   SIZE_EQUITY_PERCENT,
   SIZE_FIXED_LOTS
};

input group "Position Sizing"
input PositionSizing InpSizing = SIZE_FIXED_LOTS;
input double InpRiskPercent = 0.5;
input double InpFixedLots = 0.04; // Must split into two valid 50% halves
input ulong  InpMagic = 26011001;
input ulong  InpDeviationPoints = 20;
input int    InpMaxSpreadPoints = 0; // 0 disables the entry spread filter

input group "Stops and ATR Management (completed M15 candles)"
input double InpStopBufferPrice = 1.0; // Price units beyond opposite M15 boundary (gold: 1.000)
input double InpBreakEvenR = 1.0; // Move stop to entry after M1 close at this R; 0 disables early BE
input int    InpATRPeriod = 14;
input double InpTrailingATR = 2.0;

input group "Broker Timezone (explicit; also used in the tester)"
input double        InpBrokerUTCOffset = 2.0;
input BrokerDSTRule InpBrokerDSTRule = BROKER_DST_EUROPE;
input int           InpBrokerDSTMinutes = 60;

input group "Asian Session (GMT+2 winter reference)"
input bool InpTradeAsian = true;
input bool InpAsianMidpoint = false; // Second (midpoint) entry for this session
input int  InpAsianOpenHour = 1;
input int  InpAsianOpenMin = 0;
input int  InpAsianCloseHour = 2; // Session setting only; does not end trade management
input int  InpAsianCloseMin = 0;

input group "London Session (GMT+2 winter reference)"
input bool InpTradeLondon = true;
input bool InpLondonMidpoint = false; // Second (midpoint) entry for this session
input int  InpLondonOpenHour = 11;
input int  InpLondonOpenMin = 0;
input int  InpLondonCloseHour = 15; // Session setting only; does not end trade management
input int  InpLondonCloseMin = 0;

input group "NY Session (UTC winter reference)"
input bool InpTradeNY = false; // Disabled by default (weakest session in backtest)
input bool InpNYMidpoint = false; // Second (midpoint) entry for this session
input int  InpNYOpenHour = 13;
input int  InpNYOpenMin = 30;
input int  InpNYCloseHour = 21; // Session setting only; does not end trade management
input int  InpNYCloseMin = 0;

input group "Signal Monitoring"
input int InpDaysToMonitor = 5; // Same calendar-day horizon as the indicator

struct EASession
{
   string name;
   int open_minutes;
   bool enabled;
   bool midpoint;
};

struct EASessionRange
{
   int session;
   datetime start;
   datetime end;
   datetime next_session;
   double high;
   double low;
   bool loaded;
   bool evaluated;
   bool second_attempted;
   bool reversal_attempted;
};

CTrade g_trade;
EASession g_sessions[3];
EASessionRange g_ranges[];
int g_atr = INVALID_HANDLE;
int g_visual_indicator = INVALID_HANDLE;
string g_visual_name = "";
bool g_visual_attached = false;
datetime g_day = 0;
datetime g_start_bar = 0;
datetime g_last_signal_bar = 0;
datetime g_last_warning = 0;
struct ScaleOutTrigger
{
   ulong identifier;
   string key;
   bool armed;
};
ScaleOutTrigger g_triggers[];

void Warn(const string message)
{
   if(TimeCurrent() - g_last_warning >= 60 || g_last_warning == 0)
   {
      Print("Market Sessions EA: ", message);
      g_last_warning = TimeCurrent();
   }
}

void DebugSignal(const string message)
{
   if(InpDebugSignals)
      Print("Market Sessions EA [debug] ", message);
}

bool ConfigureEASession(const int index, const string name, const bool enabled,
                        const bool midpoint,
                        const int open_hour, const int open_minute,
                        const int close_hour, const int close_minute)
{
   if(open_hour < 0 || open_hour > 23 || open_minute < 0 || open_minute > 59 ||
      close_hour < 0 || close_hour > 23 || close_minute < 0 || close_minute > 59 ||
      (open_hour == close_hour && open_minute == close_minute))
   {
      Print("Invalid ", name, " times: hours 0-23, minutes 0-59 and distinct endpoints required.");
      return false;
   }
   g_sessions[index].name = name;
   g_sessions[index].enabled = enabled;
   g_sessions[index].midpoint = midpoint;
   g_sessions[index].open_minutes = open_hour * 60 + open_minute;
   return true;
}

bool AttachSessionBoxes()
{
   if(!InpShowSessionBoxes ||
      (MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)))
      return true;
   g_visual_name = StringFormat("MSB EA %I64u %I64u", InpMagic, GetMicrosecondCount());
   g_visual_indicator = iCustom(_Symbol, _Period, "Market_Sessions_Boxes",
      InpBrokerUTCOffset, InpBrokerDSTRule, InpBrokerDSTMinutes, false,
      InpAsianOpenHour, InpAsianOpenMin, InpAsianCloseHour, InpAsianCloseMin, InpBoxTransparency,
      InpLondonOpenHour, InpLondonOpenMin, InpLondonCloseHour, InpLondonCloseMin, InpBoxTransparency,
      InpNYOpenHour, InpNYOpenMin, InpNYCloseHour, InpNYCloseMin, InpBoxTransparency,
      true, true, 1, InpDaysToMonitor, g_visual_name);
   if(g_visual_indicator == INVALID_HANDLE)
   {
      Print("Cannot load session boxes. Compile Market_Sessions_Boxes.mq5 with ",
            "Market_Sessions_Core.mqh in MQL5/Indicators, then reattach the EA. Error: ",
            GetLastError());
      return false;
   }
   if(!ChartIndicatorAdd(ChartID(), 0, g_visual_indicator))
   {
      Print("Cannot attach session boxes to the EA chart. Error: ", GetLastError());
      return false;
   }
   g_visual_attached = true;
   ChartRedraw();
   return true;
}

int OnInit()
{
   if(!MathIsValidNumber(InpRiskPercent) || !MathIsValidNumber(InpFixedLots) ||
      !MathIsValidNumber(InpStopBufferPrice) || !MathIsValidNumber(InpTrailingATR) ||
      !MathIsValidNumber(InpBreakEvenR) || InpBreakEvenR < 0 ||
      !MathIsValidNumber(InpBrokerUTCOffset) ||
      InpSizing < SIZE_EQUITY_PERCENT || InpSizing > SIZE_FIXED_LOTS ||
      (InpSizing == SIZE_EQUITY_PERCENT && (InpRiskPercent <= 0 || InpRiskPercent > 100)) ||
      (InpSizing == SIZE_FIXED_LOTS && InpFixedLots <= 0) ||
      InpATRPeriod < 1 || InpStopBufferPrice < 0 || InpTrailingATR <= 0 ||
      InpMagic == 0 || InpMaxSpreadPoints < 0 ||
      InpBrokerUTCOffset < -14 || InpBrokerUTCOffset > 14 ||
      InpBrokerDSTRule < BROKER_DST_NONE || InpBrokerDSTRule > BROKER_DST_NZ ||
      InpBrokerDSTMinutes < 1 || InpBrokerDSTMinutes > 120 ||
      InpDaysToMonitor < 1 || InpDaysToMonitor > 30 ||
      InpBoxTransparency < 0 || InpBoxTransparency > 100)
   {
      Print("Invalid sizing, stop buffer, break-even, ATR, magic, spread, timezone or monitoring inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("This two-entry EA requires a hedging account for independent 2R management.");
      return INIT_FAILED;
   }
   if(!ConfigureEASession(0, "ASIAN", InpTradeAsian, InpAsianMidpoint, InpAsianOpenHour, InpAsianOpenMin,
                         InpAsianCloseHour, InpAsianCloseMin) ||
      !ConfigureEASession(1, "LONDON", InpTradeLondon, InpLondonMidpoint, InpLondonOpenHour, InpLondonOpenMin,
                         InpLondonCloseHour, InpLondonCloseMin) ||
      !ConfigureEASession(2, "NY", InpTradeNY, InpNYMidpoint, InpNYOpenHour, InpNYOpenMin,
                         InpNYCloseHour, InpNYCloseMin))
      return INIT_PARAMETERS_INCORRECT;
   g_atr = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   if(g_atr == INVALID_HANDLE)
   {
      Print("Cannot initialize M15 ATR. Error: ", GetLastError());
      return INIT_FAILED;
   }
   if(!EventSetTimer(5))
   {
      Print("Cannot initialize pending-order expiry timer. Error: ", GetLastError());
      return INIT_FAILED;
   }
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetAsyncMode(false);
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & (SYMBOL_FILLING_FOK | SYMBOL_FILLING_IOC)) == 0 ||
      !g_trade.SetTypeFillingBySymbol(_Symbol))
   {
      Print("EA requires immediate FOK or IOC order filling. Error: ", GetLastError());
      return INIT_FAILED;
   }
   if(!AttachSessionBoxes())
      return INIT_FAILED;
   DebugSignal(StringFormat("Initialized %s: entries=%s Asian=%s London=%s NY=%s, server time=%s, broker UTC offset=%.2f DST rule=%d shift=%d min, buffer=%.5f, max spread=%d points, deviation=%I64u points; broker volume min=%.8f step=%.8f max=%.8f, tick size=%.8f stop level=%d freeze level=%d points, filling flags=%d.",
      _Symbol, InpEnableEA ? "on" : "off", InpTradeAsian ? "on" : "off",
      InpTradeLondon ? "on" : "off", InpTradeNY ? "on" : "off",
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), InpBrokerUTCOffset,
      (int)InpBrokerDSTRule, InpBrokerDSTMinutes, InpStopBufferPrice, InpMaxSpreadPoints,
      InpDeviationPoints, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX),
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE),
      (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
      (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL), (int)filling));
   Print("Market Sessions EA: explicit broker timezone UTC", InpBrokerUTCOffset,
         ", DST rule ", (int)InpBrokerDSTRule,
         ". Each entry uses the full risk/lot input; combined risk can be twice the setting.",
         " RSI is display-only. Use a demo account first.");
   if(!InpEnableEA)
      Print("EA entries disabled: midpoint orders will be cancelled; existing trades remain managed.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_visual_attached)
   {
      if(!ChartIndicatorDelete(ChartID(), 0, g_visual_name))
         Print("Cannot remove EA-owned session indicator. Error: ", GetLastError());
      g_visual_attached = false;
   }
   if(g_visual_indicator != INVALID_HANDLE)
   {
      IndicatorRelease(g_visual_indicator);
      g_visual_indicator = INVALID_HANDLE;
   }
   if(g_atr != INVALID_HANDLE)
      IndicatorRelease(g_atr);
}

datetime EAServerTime(const datetime reference, const int session)
{
   datetime utc = SessionUTC(reference, session);
   int base = (int)MathRound(InpBrokerUTCOffset * 60);
   return utc + (base + (IsDST(utc, InpBrokerDSTRule, base, InpBrokerDSTMinutes) ?
                        InpBrokerDSTMinutes : 0)) * 60;
}

bool RebuildRanges(const datetime now)
{
   MqlDateTime date;
   if(!TimeToStruct(now, date))
   {
      Warn("Cannot convert server date.");
      return false;
   }
   date.hour = 0;
   date.min = 0;
   date.sec = 0;
   datetime today = StructToTime(date);
   if(today == g_day)
      return true;
   EASessionRange previous[];
   ArrayCopy(previous, g_ranges);
   EASessionRange next[];
   datetime oldest = today - (InpDaysToMonitor - 1) * 86400;
   for(int day = InpDaysToMonitor + 1; day >= -1; day--)
   {
      datetime midnight = today - day * 86400;
      for(int s = 0; s < 3; s++)
      {
         if(!g_sessions[s].enabled)
            continue;
         datetime open_ref = midnight + g_sessions[s].open_minutes * 60;
         EASessionRange range = {};
         range.session = s;
         range.start = EAServerTime(open_ref, s);
         range.end = OpeningRangeStart(range.start) + PeriodSeconds(PERIOD_M15);
         int openings[3];
         for(int j = 0; j < 3; j++)
            openings[j] = g_sessions[j].open_minutes;
         datetime next_utc = NextSessionUTC(midnight, SessionUTC(open_ref, s), openings);
         int base = (int)MathRound(InpBrokerUTCOffset * 60);
         range.next_session = next_utc + (base +
            (IsDST(next_utc, InpBrokerDSTRule, base, InpBrokerDSTMinutes) ?
             InpBrokerDSTMinutes : 0)) * 60;
         if(range.next_session <= oldest || range.next_session <= range.end)
            continue;
         for(int i = 0; i < ArraySize(previous); i++)
            if(previous[i].session == s && previous[i].start == range.start &&
               previous[i].end == range.end && previous[i].next_session == range.next_session)
            {
               range = previous[i];
               break;
            }
         int count = ArraySize(next);
         if(ArrayResize(next, count + 1) != count + 1)
         {
            Warn("Cannot allocate session ranges.");
            return false;
         }
         next[count] = range;
      }
   }
   ArraySwap(g_ranges, next);
   g_day = today;
   return true;
}

bool ReadATR(double &atr)
{
   double values[1];
   if(CopyBuffer(g_atr, 0, 1, 1, values) != 1 ||
      !MathIsValidNumber(values[0]) || values[0] <= 0)
   {
      Warn("Completed M15 ATR is unavailable; waiting for history.");
      return false;
   }
   atr = values[0];
   return true;
}

bool ExternalSymbolOccupied()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) != 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         return true;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderGetTicket(i) != 0 && OrderGetString(ORDER_SYMBOL) == _Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         return true;
   return false;
}

double DirectionalExposure(const bool buy)
{
   double volume = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) != 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) == buy)
         volume += PositionGetDouble(POSITION_VOLUME);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderGetTicket(i) == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool order_buy = type == ORDER_TYPE_BUY || type == ORDER_TYPE_BUY_LIMIT ||
                       type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT;
      if(order_buy == buy)
         volume += OrderGetDouble(ORDER_VOLUME_CURRENT);
   }
   return volume;
}

bool TradingAllowed()
{
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      Warn("Algorithmic trading is disabled; trade requests are not sent.");
      return false;
   }
   return true;
}

bool HasPendingEAOrder()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderGetTicket(i) != 0 && OrderGetString(ORDER_SYMBOL) == _Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagic &&
         (OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY ||
          OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_SELL))
         return true;
   return false;
}

bool ArmScaleOut(const ulong identifier, const bool reached)
{
   bool tester = (bool)MQLInfoInteger(MQL_TESTER);
   int index = -1;
   for(int i = 0; i < ArraySize(g_triggers); i++)
      if(g_triggers[i].identifier == identifier)
      {
         index = i;
         break;
      }
   if(index < 0)
   {
      index = ArraySize(g_triggers);
      if(ArrayResize(g_triggers, index + 1) != index + 1)
      {
         Warn("Cannot allocate a position's 2R marker.");
         return false;
      }
      uint hash = 2166136261;
      string account = AccountInfoString(ACCOUNT_SERVER) + ":" +
                       IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
      for(int i = 0; i < StringLen(account); i++)
         hash = (hash ^ StringGetCharacter(account, i)) * 16777619;
      g_triggers[index].key = StringFormat("MSBEA_%u_%I64u_%I64u_2R", hash, InpMagic, identifier);
      g_triggers[index].identifier = identifier;
      g_triggers[index].armed = false;
   }
   string key = g_triggers[index].key;
   if(!tester && !g_triggers[index].armed && GlobalVariableCheck(key))
   {
      double saved;
      if(!GlobalVariableGet(key, saved) || saved != 1.0)
      {
         Warn("Cannot read the saved 2R trigger; scale-out suspended.");
         return false;
      }
      g_triggers[index].armed = true;
   }
   if(reached && !g_triggers[index].armed)
   {
      if(!tester)
      {
         if(GlobalVariableSet(key, 1.0) == 0)
         {
            Warn("Cannot persist the 2R trigger; scale-out will retry.");
            return false;
         }
         GlobalVariablesFlush();
      }
      g_triggers[index].armed = true;
   }
   return g_triggers[index].armed;
}

bool TradeResult(const bool sent, const string operation)
{
   uint code = g_trade.ResultRetcode();
   if(sent && code == TRADE_RETCODE_PLACED)
   {
      Print(operation, " submitted but not yet filled; awaiting the broker order.");
      return false;
   }
   DebugSignal(StringFormat("%s response: sent=%s retcode=%u (%s), order=%I64u deal=%I64u volume=%.8f price=%.5f.",
      operation, sent ? "yes" : "no", code, g_trade.ResultRetcodeDescription(),
      g_trade.ResultOrder(), g_trade.ResultDeal(), g_trade.ResultVolume(), g_trade.ResultPrice()));
   if(!sent || (code != TRADE_RETCODE_DONE && code != TRADE_RETCODE_DONE_PARTIAL))
   {
      Print(operation, " failed: ", code, " ", g_trade.ResultRetcodeDescription(),
            ", error ", GetLastError());
      return false;
   }
   return true;
}

bool EntryVolume(const bool buy, const double price, const double stop,
                 const double equity, const bool market_order, double &volume)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maximum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double limit = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);
   if(step <= 0 || minimum <= 0 || maximum < minimum)
   {
      Warn("Invalid symbol tick size or volume specification.");
      return false;
   }
   if(limit > 0)
      maximum = MathMin(maximum, MathMax(0, limit - DirectionalExposure(buy)));
   ENUM_ORDER_TYPE type = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   volume = InpFixedLots;
   if(InpSizing == SIZE_EQUITY_PERCENT)
   {
      double loss;
      double allowance = market_order ? (double)InpDeviationPoints * _Point : 0;
      double worst_price = price + (buy ? 1 : -1) * allowance;
      if(!OrderCalcProfit(type, _Symbol, 1.0, worst_price, stop, loss) || loss >= 0)
      {
         Print("Cannot calculate range stop risk. Error: ", GetLastError());
         return false;
      }
      double budget = equity * InpRiskPercent / 100.0;
      volume = FloorVolume(MathMin(maximum, budget / MathAbs(loss)), 2 * step);
   }
   double half = volume / 2;
   if(volume < minimum || volume > maximum || half < minimum ||
      MathAbs(FloorVolume(volume, step) - volume) > step * 1e-6 ||
      MathAbs(FloorVolume(half, step) - half) > step * 1e-6)
   {
      Print("Entry skipped: volume ", DoubleToString(volume, 8),
            " cannot be split into two equal broker-valid halves. Min=", minimum,
            ", step=", step, ", max=", maximum, ". Increase budget or choose a valid fixed lot.");
      return false;
   }
   return true;
}

string SessionEntryComment(const datetime start, const bool second)
{
   return (second ? "MSBM " : "MSBH ") + IntegerToString((long)start);
}

bool SessionTradeState(const EASessionRange &range, ulong &first_id,
                       bool &second_filled, bool &profit_taken)
{
   first_id = 0;
   second_filled = false;
   profit_taken = false;
   if(!HistorySelect(range.start, TimeCurrent()))
   {
      Warn("Cannot recover session trades; new entries suspended.");
      return false;
   }
   ulong second_id = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol ||
         (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic ||
         HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      string comment = HistoryDealGetString(deal, DEAL_COMMENT);
      ulong order = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
      string order_comment = HistoryOrderGetString(order, ORDER_COMMENT);
      ulong identifier = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(comment == SessionEntryComment(range.start, false) ||
         order_comment == SessionEntryComment(range.start, false))
         first_id = identifier;
      if(comment == SessionEntryComment(range.start, true) ||
         order_comment == SessionEntryComment(range.start, true))
      {
         second_id = identifier;
         second_filled = true;
      }
   }
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      ulong identifier = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(identifier == 0 || (identifier != first_id && identifier != second_id))
         continue;
      long leg = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if((leg == DEAL_ENTRY_OUT || leg == DEAL_ENTRY_OUT_BY || leg == DEAL_ENTRY_INOUT) &&
         HistoryDealGetDouble(deal, DEAL_PROFIT) > 0)
         profit_taken = true;
   }
   return true;
}

void EnterTrades(const EASessionRange &range, const int direction, const MqlTick &tick,
                 const bool reversal = false)
{
   DebugSignal(StringFormat("%s %s candidate: session open=%s next open=%s direction=%s range=[%.5f, %.5f] bid=%.5f ask=%.5f spread=%.1f points.",
      g_sessions[range.session].name, reversal ? "reversal" : "breakout",
      TimeToString(range.start, TIME_DATE | TIME_MINUTES),
      TimeToString(range.next_session, TIME_DATE | TIME_MINUTES),
      direction > 0 ? "BUY" : "SELL", range.low, range.high, tick.bid, tick.ask,
      (tick.ask - tick.bid) / _Point));
   if(!InpEnableEA)
   {
      Print(g_sessions[range.session].name, " breakout skipped: EA entries disabled.");
      return;
   }
   if(ExternalSymbolOccupied() || HasPendingEAOrder())
   {
      Print(g_sessions[range.session].name,
            " breakout skipped: external symbol exposure or unresolved market request.");
      return;
   }
   if(!TradingAllowed())
      return;
   ulong first_id;
   bool second_filled, profit_taken;
   if(!SessionTradeState(range, first_id, second_filled, profit_taken) ||
      (!reversal && (first_id != 0 || second_filled || profit_taken)) ||
      (reversal && (first_id == 0 || second_filled)))
   {
      Print("Session entry skipped: already traded, profit locked or history unavailable.");
      return;
   }
   if(InpMaxSpreadPoints > 0 && (tick.ask - tick.bid) / _Point > InpMaxSpreadPoints)
   {
      Print("Breakout skipped: spread exceeds entry limit.");
      return;
   }
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0)
   {
      Warn("Invalid symbol tick size.");
      return;
   }
   bool buy = direction > 0;
   bool allow_midpoint = !reversal && g_sessions[range.session].midpoint;
   double price = buy ? tick.ask : tick.bid;
   double stop = StopPrice((buy ? range.low : range.high) +
                           (buy ? -1 : 1) * InpStopBufferPrice, tick_size, buy);
   double midpoint = StopPrice((range.high + range.low) / 2, tick_size, buy);
   double minimum_distance = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   DebugSignal(StringFormat("%s entry check: price=%.5f stop=%.5f stop distance from executable quote=%.5f broker minimum=%.5f (%.1f points), midpoint=%s at %.5f, tick size=%.5f.",
      g_sessions[range.session].name, price, stop, buy ? tick.bid - stop : stop - tick.ask,
      minimum_distance, minimum_distance / _Point, allow_midpoint ? "on" : "off", midpoint, tick_size));
   if(stop <= 0 || midpoint <= 0 ||
      (buy ? tick.bid - stop : stop - tick.ask) < minimum_distance ||
      (allow_midpoint && ((buy ? midpoint - stop : stop - midpoint) < minimum_distance ||
       (buy ? tick.ask - midpoint : midpoint - tick.bid) < minimum_distance ||
       (buy ? midpoint >= tick.ask : midpoint <= tick.bid))) ||
      (buy ? stop >= tick.bid : stop <= tick.ask) ||
      range.next_session <= tick.time)
   {
      Print("Breakout pair skipped: range stop/midpoint violates broker price distance or has expired.");
      return;
   }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double market_volume, limit_volume = 0;
   if(!EntryVolume(buy, price, stop, equity, true, market_volume) ||
      (allow_midpoint && !EntryVolume(buy, midpoint, stop, equity, false, limit_volume)))
      return;
   DebugSignal(StringFormat("%s sizing: mode=%s equity=%.2f requested market lots=%.8f midpoint lots=%.8f.",
      g_sessions[range.session].name, InpSizing == SIZE_FIXED_LOTS ? "fixed" : "equity-percent",
      equity, market_volume, limit_volume));
   double limit = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);
   if(limit > 0 &&
      DirectionalExposure(buy) + market_volume + limit_volume > limit + 1e-8)
   {
      Print("Breakout pair skipped: combined volume exceeds broker directional limit.");
      return;
   }
   ENUM_ORDER_TYPE type = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double market_margin, limit_margin = 0;
   if(!OrderCalcMargin(type, _Symbol, market_volume, price, market_margin) ||
      (allow_midpoint && !OrderCalcMargin(type, _Symbol, limit_volume, midpoint, limit_margin)) ||
      market_margin + limit_margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      Print("Breakout pair skipped: insufficient margin or margin calculation failed. Error: ", GetLastError());
      return;
   }
   DebugSignal(StringFormat("%s margin: market=%.2f midpoint=%.2f free=%.2f. Submitting once; no price retry.",
      g_sessions[range.session].name, market_margin, limit_margin,
      AccountInfoDouble(ACCOUNT_MARGIN_FREE)));
   string comment = reversal ? "MSBR " + IntegerToString((long)range.start) :
                               SessionEntryComment(range.start, false);
   bool sent = buy ? g_trade.Buy(market_volume, _Symbol, 0, stop, 0, comment) :
                     g_trade.Sell(market_volume, _Symbol, 0, stop, 0, comment);
   if(!TradeResult(sent, reversal ? "M15 reversal entry" : "High-risk breakout entry"))
   {
      Print("Market entry was not confirmed filled; no follow-up entry submitted.");
      return;
   }
   Print(comment, " entry filled. Volume=", g_trade.ResultVolume(), ", SL=", stop);
   if(!reversal && g_sessions[range.session].midpoint)
      Print("Midpoint trigger armed only while first trade is open in drawdown and session has no profit.");
}

void ProcessM15Reversals(const MqlTick &tick)
{
   if(!InpEnableEA || !InpEnableM15Reversal || !RebuildRanges(tick.time))
      return;
   MqlRates completed[];
   if(CopyRates(_Symbol, PERIOD_M15, 1, 1, completed) != 1 ||
      !SeriesInfoInteger(_Symbol, PERIOD_M15, SERIES_SYNCHRONIZED))
   {
      Warn("Completed M15 candle unavailable for reversal; retrying.");
      return;
   }
   datetime closed = completed[0].time + PeriodSeconds(PERIOD_M15);
   if(closed <= g_start_bar || iTime(_Symbol, PERIOD_M15, 0) != closed)
      return;
   for(int i = 0; i < ArraySize(g_ranges); i++)
   {
      if(g_ranges[i].reversal_attempted || closed <= g_ranges[i].end ||
         tick.time >= g_ranges[i].next_session)
         continue;
      ulong first_id;
      bool second_filled, profit_taken;
      if(!SessionTradeState(g_ranges[i], first_id, second_filled, profit_taken))
         continue;
      if(first_id == 0)
         continue;
      if(second_filled)
      {
         g_ranges[i].reversal_attempted = true;
         continue;
      }
      string comment = "MSBR " + IntegerToString((long)g_ranges[i].start);
      bool reversal_filled = false;
      for(int d = 0; d < HistoryDealsTotal(); d++)
      {
         ulong deal = HistoryDealGetTicket(d);
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol ||
            (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic ||
            HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
            continue;
         ulong order = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
         if(HistoryDealGetString(deal, DEAL_COMMENT) == comment ||
            HistoryOrderGetString(order, ORDER_COMMENT) == comment)
            reversal_filled = true;
      }
      if(reversal_filled)
      {
         g_ranges[i].reversal_attempted = true;
         continue;
      }
      bool first_open = false;
      for(int p = PositionsTotal() - 1; p >= 0; p--)
         if(PositionGetTicket(p) != 0 &&
            (ulong)PositionGetInteger(POSITION_IDENTIFIER) == first_id)
            first_open = true;
      if(first_open)
         continue;
      if(!HistorySelectByPosition(first_id))
      {
         Warn("Cannot recover first position history for reversal; retrying.");
         continue;
      }
      int original_direction = 0;
      datetime exit_time = 0;
      for(int d = 0; d < HistoryDealsTotal(); d++)
      {
         ulong deal = HistoryDealGetTicket(d);
         long leg = HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(leg == DEAL_ENTRY_IN)
            original_direction = HistoryDealGetInteger(deal, DEAL_TYPE) == DEAL_TYPE_BUY ? 1 : -1;
         if(leg == DEAL_ENTRY_OUT || leg == DEAL_ENTRY_OUT_BY)
         {
            datetime deal_time = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
            if(deal_time > exit_time)
               exit_time = deal_time;
         }
      }
      if(original_direction == 0 || exit_time == 0 || closed <= exit_time)
         continue;
      if(!g_ranges[i].loaded)
      {
         if(!LoadOpeningRange(_Symbol, g_ranges[i].start, tick.time,
                              g_ranges[i].high, g_ranges[i].low))
         {
            Warn("Opening range unavailable for reversal; retrying.");
            continue;
         }
         g_ranges[i].loaded = true;
      }
      bool opposite_break = original_direction > 0 ?
                            completed[0].close < g_ranges[i].low :
                            completed[0].close > g_ranges[i].high;
      if(!opposite_break)
         continue;
      g_ranges[i].reversal_attempted = true;
      EnterTrades(g_ranges[i], -original_direction, tick, true);
   }
}

bool CancelLegacyMidpointOrders()
{
   bool clear = true;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic ||
         (OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_BUY_LIMIT &&
          OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_SELL_LIMIT))
         continue;
      if(!TradingAllowed())
      {
         clear = false;
         continue;
      }
      bool sent = g_trade.OrderDelete(ticket);
      if(!sent || g_trade.ResultRetcode() != TRADE_RETCODE_DONE)
      {
         clear = false;
         Warn(StringFormat("Legacy midpoint cancellation failed: %u %s",
                           g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      }
      else
         Print("Unsafe resting midpoint order cancelled: ", ticket);
   }
   return clear;
}

void ProcessMidpointTriggers(const MqlTick &tick)
{
   if(!InpEnableEA || ExternalSymbolOccupied() || HasPendingEAOrder() ||
      !RebuildRanges(tick.time))
      return;
   for(int i = 0; i < ArraySize(g_ranges); i++)
   {
      if(g_ranges[i].second_attempted || !g_sessions[g_ranges[i].session].midpoint ||
         tick.time < g_ranges[i].end || tick.time >= g_ranges[i].next_session)
         continue;
      ulong first_id;
      bool second_filled, profit_taken;
      if(!SessionTradeState(g_ranges[i], first_id, second_filled, profit_taken))
         continue;
      if(second_filled || profit_taken)
      {
         g_ranges[i].second_attempted = true;
         if(profit_taken)
            Print("Session ", g_ranges[i].start, " done: profitable exit; midpoint trigger cancelled.");
         continue;
      }
      if(first_id == 0)
         continue;
      ulong ticket = 0;
      for(int p = PositionsTotal() - 1; p >= 0; p--)
      {
         ulong candidate = PositionGetTicket(p);
         if(candidate != 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic &&
            (ulong)PositionGetInteger(POSITION_IDENTIFIER) == first_id)
         {
            ticket = candidate;
            break;
         }
      }
      if(ticket == 0)
      {
         g_ranges[i].second_attempted = true;
         continue;
      }
      bool buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double executable = buy ? tick.bid : tick.ask;
      if(!g_ranges[i].loaded)
      {
         if(!LoadOpeningRange(_Symbol, g_ranges[i].start, tick.time,
                              g_ranges[i].high, g_ranges[i].low))
         {
            Warn("Cannot recover opening range for midpoint trigger.");
            continue;
         }
         g_ranges[i].loaded = true;
      }
      if(!MidpointEntryEligible(true, false, false, buy, entry, executable,
                                tick.ask, tick.bid, (g_ranges[i].high + g_ranges[i].low) / 2))
         continue;
      if(InpMaxSpreadPoints > 0 && (tick.ask - tick.bid) / _Point > InpMaxSpreadPoints)
         continue;
      if(!TradingAllowed())
         continue;
      double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tick_size <= 0)
      {
         Warn("Invalid tick size for midpoint trigger.");
         continue;
      }
      double stop = StopPrice((buy ? g_ranges[i].low : g_ranges[i].high) +
         (buy ? -1 : 1) * InpStopBufferPrice, tick_size, buy);
      double distance = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      if(stop <= 0 || (buy ? tick.bid - stop : stop - tick.ask) < distance ||
         (buy ? stop >= tick.bid : stop <= tick.ask))
      {
         Warn("Midpoint entry blocked by range stop distance.");
         continue;
      }
      double price = buy ? tick.ask : tick.bid;
      double volume, margin;
      if(!EntryVolume(buy, price, stop, AccountInfoDouble(ACCOUNT_EQUITY), true, volume))
         continue;
      if(!OrderCalcMargin(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol,
                          volume, price, margin) ||
         margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
      {
         Warn("Midpoint entry blocked by insufficient margin or margin calculation failure.");
         continue;
      }
      // Recheck session history and first position immediately before sending.
      if(!SessionTradeState(g_ranges[i], first_id, second_filled, profit_taken) ||
         second_filled || profit_taken || !PositionSelectByTicket(ticket))
         continue;
      g_ranges[i].second_attempted = true;
      string comment = SessionEntryComment(g_ranges[i].start, true);
      bool sent = buy ? g_trade.Buy(volume, _Symbol, 0, stop, 0, comment) :
                        g_trade.Sell(volume, _Symbol, 0, stop, 0, comment);
      TradeResult(sent, "Drawdown-only midpoint entry");
   }
}

void OnTimer()
{
   CancelLegacyMidpointOrders();
}

// Recover original risk and scale-out progress from broker history, including after restart.
bool PositionHistory(const ulong identifier, const bool buy,
                     double &entry, double &risk, double &initial_volume,
                     double &scaled_volume)
{
   if(!HistorySelectByPosition(identifier))
   {
      Warn("Cannot load position history; management will retry.");
      return false;
   }
   entry = 0;
   initial_volume = 0;
   scaled_volume = 0;
   double initial_stop = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      ENUM_DEAL_ENTRY leg = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic ||
         leg == DEAL_ENTRY_INOUT || leg == DEAL_ENTRY_OUT_BY)
      {
         Warn("Position contains external trades or a reversal; automatic management suspended.");
         return false;
      }
      double volume = HistoryDealGetDouble(deal, DEAL_VOLUME);
      if(leg == DEAL_ENTRY_IN)
      {
         if((type == DEAL_TYPE_BUY) != buy)
         {
            Warn("Position direction differs from its entry history; management suspended.");
            return false;
         }
         double sl = HistoryDealGetDouble(deal, DEAL_SL);
         if(initial_stop == 0)
            initial_stop = sl;
         if(sl <= 0 || MathAbs(sl - initial_stop) > _Point / 2)
         {
            Warn("Original protective stop is missing or inconsistent in deal history.");
            return false;
         }
         initial_volume += volume;
         entry += HistoryDealGetDouble(deal, DEAL_PRICE) * volume;
      }
      else if(leg == DEAL_ENTRY_OUT &&
              HistoryDealGetInteger(deal, DEAL_REASON) == DEAL_REASON_EXPERT)
         scaled_volume += volume;
   }
   if(initial_volume <= 0 || initial_stop <= 0)
   {
      Warn("Original entry volume or stop is unavailable; management will retry.");
      return false;
   }
   entry /= initial_volume;
   risk = buy ? entry - initial_stop : initial_stop - entry;
   if(risk <= 0)
   {
      Warn("Original entry has no positive stop risk; management suspended.");
      return false;
   }
   return true;
}

bool ClosePartial(const ulong ticket, const bool buy, const double volume,
                  const MqlTick &tick)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = _Symbol;
   request.magic = InpMagic;
   request.volume = volume;
   request.type = buy ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = buy ? tick.bid : tick.ask;
   request.deviation = InpDeviationPoints;
   request.comment = "MSB 2R half";
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)
      request.type_filling = ORDER_FILLING_FOK;
   else if((filling & SYMBOL_FILLING_IOC) != 0)
      request.type_filling = ORDER_FILLING_IOC;
   else
   {
      Warn("No supported filling policy for the partial close.");
      return false;
   }
   MqlTradeCheckResult check = {};
   if(!OrderCheck(request, check))
   {
      Warn(StringFormat("2R partial-close check failed: %u %s", check.retcode, check.comment));
      return false;
   }
   bool sent = OrderSend(request, result);
   if(sent && result.retcode == TRADE_RETCODE_PLACED)
   {
      Warn("2R close submitted but not yet filled; awaiting the broker order.");
      return false;
   }
   if(!sent ||
      (result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_DONE_PARTIAL))
   {
      Warn(StringFormat("2R partial close failed: %u %s", result.retcode, result.comment));
      return false;
   }
   Print("2R scale-out accepted for position ", ticket, ": volume=", result.volume);
   return true;
}

void ManagePositions(const MqlTick &tick)
{
   if(HasPendingEAOrder())
   {
      Warn("EA order is pending; waiting before sending further position requests.");
      return;
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      bool buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      ulong identifier = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      double current_volume = PositionGetDouble(POSITION_VOLUME);
      double old_stop = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double entry, risk, original_volume, scaled;
      if(!PositionHistory(identifier, buy, entry, risk, original_volume, scaled))
         continue;
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(step <= 0 || minimum <= 0 || tick_size <= 0)
      {
         Warn("Invalid symbol specification for position management.");
         continue;
      }
      double target_volume = original_volume / 2;
      if(MathAbs(FloorVolume(target_volume, step) - target_volume) > step * 1e-6 ||
         target_volume < minimum ||
         MathAbs(current_volume + scaled - original_volume) > step * 1e-6)
      {
         Warn("Position volume cannot support the original 50% scale-out or was externally changed.");
         continue;
      }
      double market = buy ? tick.bid : tick.ask;
      double profit_distance = buy ? market - entry : entry - market;
      if(scaled < target_volume - step * 1e-6)
      {
         if(ArmScaleOut(identifier, scaled > step * 1e-6 || profit_distance >= 2 * risk))
         {
            double remaining = FloorVolume(target_volume - scaled, step);
            if(remaining < minimum || current_volume - remaining < minimum)
            {
               Warn("Broker partial fill left an invalid remainder for the 50% scale-out.");
               continue;
            }
            if(!TradingAllowed() || !PositionSelectByTicket(ticket))
               continue;
            if(!ClosePartial(ticket, buy, remaining, tick))
               continue;
            if(!PositionSelectByTicket(ticket) ||
               !PositionHistory(identifier, buy, entry, risk, original_volume, scaled) ||
               scaled < target_volume - step * 1e-6)
               continue;
            old_stop = PositionGetDouble(POSITION_SL);
            tp = PositionGetDouble(POSITION_TP);
         }
      }
      bool scale_complete = scaled >= target_volume - step * 1e-6;
      if(!scale_complete)
      {
         if(InpBreakEvenR == 0)
            continue;
         MqlRates completed[];
         if(CopyRates(_Symbol, PERIOD_M1, 1, 1, completed) != 1)
         {
            Warn("Cannot read completed M1 candle for early break-even; retrying.");
            continue;
         }
         if(completed[0].time + PeriodSeconds(PERIOD_M1) <=
            (datetime)PositionGetInteger(POSITION_TIME))
            continue;
         double close_price = completed[0].close +
                              (buy ? 0 : completed[0].spread * _Point);
         double closed_gain = buy ? close_price - entry : entry - close_price;
         if(closed_gain < InpBreakEvenR * risk)
            continue;
      }
      if(!TradingAllowed())
         continue;
      // Round toward profit so the remaining stop is never below entry for a buy.
      double breakeven = StopPrice(entry, tick_size, !buy);
      double stop = breakeven;
      double atr;
      if(scale_complete && ReadATR(atr))
      {
         double trail = StopPrice(market + (buy ? -1 : 1) * InpTrailingATR * atr,
                                  tick_size, buy);
         stop = buy ? MathMax(breakeven, trail) : MathMin(breakeven, trail);
      }
      double distance = (double)MathMax(
         SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
         SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point;
      if((buy ? market - stop : stop - market) <= distance &&
         (buy ? market - breakeven : breakeven - market) > distance)
         stop = breakeven;
      if(old_stop > 0 && (buy ? stop <= old_stop + tick_size / 2 :
                              stop >= old_stop - tick_size / 2))
         continue;
      if((buy ? market - stop : stop - market) <= distance ||
         (old_stop > 0 && SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) > 0 &&
          (buy ? market - old_stop : old_stop - market) <=
          SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point))
      {
         Warn("Break-even/trailing stop blocked by broker stop/freeze distance; retrying.");
         continue;
      }
      if(!PositionSelectByTicket(ticket))
         continue;
      TradeResult(g_trade.PositionModify(ticket, stop, tp), "Break-even/ATR trail");
   }
   for(int i = ArraySize(g_triggers) - 1; i >= 0; i--)
   {
      bool exists = false;
      for(int p = PositionsTotal() - 1; p >= 0; p--)
         if(PositionGetTicket(p) != 0 &&
            (ulong)PositionGetInteger(POSITION_IDENTIFIER) == g_triggers[i].identifier)
            exists = true;
      if(exists)
         continue;
      string key = g_triggers[i].key;
      if(!MQLInfoInteger(MQL_TESTER) && GlobalVariableCheck(key) &&
         !GlobalVariableDel(key))
      {
         Warn("Cannot remove the closed position's 2R marker; cleanup will retry.");
         continue;
      }
      int last = ArraySize(g_triggers) - 1;
      if(i != last)
         g_triggers[i] = g_triggers[last];
      ArrayResize(g_triggers, last);
   }
}

void ProcessSignals(const datetime current_bar, const MqlTick &tick)
{
   if(!RebuildRanges(tick.time))
      return;
   bool ready = true;
   for(int i = 0; i < ArraySize(g_ranges); i++)
   {
      if(g_ranges[i].evaluated)
         continue;
      if(g_ranges[i].next_session <= tick.time)
      {
         if(g_ranges[i].start >= g_start_bar)
            DebugSignal(StringFormat("%s session opened %s expired at %s without an eligible entry signal.",
               g_sessions[g_ranges[i].session].name,
               TimeToString(g_ranges[i].start, TIME_DATE | TIME_MINUTES),
               TimeToString(g_ranges[i].next_session, TIME_DATE | TIME_MINUTES)));
         g_ranges[i].evaluated = true;
         continue;
      }
      if(g_ranges[i].end > current_bar - PeriodSeconds(PERIOD_M5))
         continue;
      if(!g_ranges[i].loaded)
      {
         if(!LoadOpeningRange(_Symbol, g_ranges[i].start, tick.time,
                              g_ranges[i].high, g_ranges[i].low))
         {
            Warn("Completed opening M15 candle is unavailable; no signal will be assumed.");
            ready = false;
            continue;
         }
         g_ranges[i].loaded = true;
         DebugSignal(StringFormat("%s opening M15 complete: session open=%s range end=%s high=%.5f low=%.5f; awaiting M5 close outside range until next open %s.",
            g_sessions[g_ranges[i].session].name,
            TimeToString(g_ranges[i].start, TIME_DATE | TIME_MINUTES),
            TimeToString(g_ranges[i].end, TIME_DATE | TIME_MINUTES),
            g_ranges[i].high, g_ranges[i].low,
            TimeToString(g_ranges[i].next_session, TIME_DATE | TIME_MINUTES)));
      }
      MqlRates rates[];
      if(CopyRates(_Symbol, PERIOD_M5, g_ranges[i].end, current_bar - 1, rates) <= 0 ||
         !SeriesInfoInteger(_Symbol, PERIOD_M5, SERIES_SYNCHRONIZED) ||
         SeriesInfoInteger(_Symbol, PERIOD_M5, SERIES_FIRSTDATE) > g_ranges[i].end)
      {
         Warn("M5 confirmation history is unavailable; waiting.");
         ready = false;
         continue;
      }
      datetime confirmation;
      int direction = FindOpeningBreak(rates, g_ranges[i].end, g_ranges[i].next_session, current_bar,
                                       g_ranges[i].high, g_ranges[i].low, confirmation);
      if(direction == 0)
      {
         if(g_ranges[i].start >= g_start_bar && ArraySize(rates) > 0)
            DebugSignal(StringFormat("%s no breakout: M5 bar=%s close=%.5f, range low=%.5f high=%.5f (close must be strictly outside).",
               g_sessions[g_ranges[i].session].name,
               TimeToString(rates[ArraySize(rates) - 1].time, TIME_DATE | TIME_MINUTES),
               rates[ArraySize(rates) - 1].close, g_ranges[i].low, g_ranges[i].high));
         continue;
      }
      g_ranges[i].evaluated = true;
      // Historical signals are consumed, never entered late or replayed after restart.
      if(confirmation == current_bar - PeriodSeconds(PERIOD_M5))
         EnterTrades(g_ranges[i], direction, tick);
      else
         DebugSignal(StringFormat("%s historical breakout at %s was not traded: EA only enters the immediately preceding M5 confirmation; current M5=%s.",
            g_sessions[g_ranges[i].session].name,
            TimeToString(confirmation, TIME_DATE | TIME_MINUTES),
            TimeToString(current_bar, TIME_DATE | TIME_MINUTES)));
   }
   if(ready)
      g_last_signal_bar = current_bar;
}

void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0 || tick.ask <= 0)
   {
      Warn("Valid symbol quotes are unavailable.");
      return;
   }
   bool legacy_clear = CancelLegacyMidpointOrders();
   ManagePositions(tick);
   if(!legacy_clear)
      return;
   ProcessMidpointTriggers(tick);
   datetime current_bar = iTime(_Symbol, PERIOD_M5, 0);
   if(current_bar <= 0)
   {
      Warn("M5 bar history is unavailable.");
      return;
   }
   if(g_start_bar == 0)
   {
      g_start_bar = current_bar;
      g_last_signal_bar = current_bar;
      DebugSignal(StringFormat("Starting at M5 bar %s; historical confirmations are not traded. No entries until a later completed confirmation.",
         TimeToString(current_bar, TIME_DATE | TIME_MINUTES)));
      return;
   }
   if(current_bar > g_start_bar && current_bar != g_last_signal_bar)
      ProcessSignals(current_bar, tick);
   ProcessM15Reversals(tick);
}
