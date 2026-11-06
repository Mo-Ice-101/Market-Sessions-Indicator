#property strict
#property version "1.02"
#property description "Opening M15 / M5 breakout and midpoint entries, 50% at 2R, ATR trail."
#property tester_indicator "Market_Sessions_Boxes.ex5"

#include <Trade/Trade.mqh>
#include "Market_Sessions_Core.mqh"

input group "EA Control"
input bool InpEnableEA = true; // Enable new entries; existing positions remain managed
input bool InpShowSessionBoxes = true; // Automatically attach matching indicator on chart
input int  InpBoxTransparency = 85; // Fill transparency 0-100; borders/levels stay visible

enum PositionSizing
{
   SIZE_EQUITY_PERCENT,
   SIZE_FIXED_LOTS
};

input group "Position Sizing"
input PositionSizing InpSizing = SIZE_EQUITY_PERCENT;
input double InpRiskPercent = 0.5;
input double InpFixedLots = 0.10;
input ulong  InpMagic = 26011001;
input ulong  InpDeviationPoints = 20;
input int    InpMaxSpreadPoints = 0; // 0 disables the entry spread filter

input group "Stops and ATR Management (completed M15 candles)"
input double InpStopBufferPoints = 10.0; // Beyond the opposite opening-range boundary
input int    InpATRPeriod = 14;
input double InpTrailingATR = 2.0;

input group "Broker Timezone (explicit; also used in the tester)"
input double        InpBrokerUTCOffset = 2.0;
input BrokerDSTRule InpBrokerDSTRule = BROKER_DST_NONE;
input int           InpBrokerDSTMinutes = 60;

input group "Asian Session (GMT+2 winter reference)"
input bool InpTradeAsian = true;
input int  InpAsianOpenHour = 1;
input int  InpAsianOpenMin = 0;
input int  InpAsianCloseHour = 2; // Session setting only; does not end trade management
input int  InpAsianCloseMin = 0;

input group "London Session (GMT+2 winter reference)"
input bool InpTradeLondon = true;
input int  InpLondonOpenHour = 11;
input int  InpLondonOpenMin = 0;
input int  InpLondonCloseHour = 15; // Session setting only; does not end trade management
input int  InpLondonCloseMin = 0;

input group "NY Session (UTC winter reference)"
input bool InpTradeNY = true;
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

bool ConfigureEASession(const int index, const string name, const bool enabled,
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
      !MathIsValidNumber(InpStopBufferPoints) || !MathIsValidNumber(InpTrailingATR) ||
      !MathIsValidNumber(InpBrokerUTCOffset) ||
      InpSizing < SIZE_EQUITY_PERCENT || InpSizing > SIZE_FIXED_LOTS ||
      (InpSizing == SIZE_EQUITY_PERCENT && (InpRiskPercent <= 0 || InpRiskPercent > 100)) ||
      (InpSizing == SIZE_FIXED_LOTS && InpFixedLots <= 0) ||
      InpATRPeriod < 1 || InpStopBufferPoints < 0 || InpTrailingATR <= 0 ||
      InpMagic == 0 || InpMaxSpreadPoints < 0 ||
      InpBrokerUTCOffset < -14 || InpBrokerUTCOffset > 14 ||
      InpBrokerDSTRule < BROKER_DST_NONE || InpBrokerDSTRule > BROKER_DST_NZ ||
      InpBrokerDSTMinutes < 1 || InpBrokerDSTMinutes > 120 ||
      InpDaysToMonitor < 1 || InpDaysToMonitor > 30 ||
      InpBoxTransparency < 0 || InpBoxTransparency > 100)
   {
      Print("Invalid sizing, ATR, magic, spread, timezone or monitoring inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("This two-entry EA requires a hedging account for independent 2R management.");
      return INIT_FAILED;
   }
   if(!ConfigureEASession(0, "ASIAN", InpTradeAsian, InpAsianOpenHour, InpAsianOpenMin,
                         InpAsianCloseHour, InpAsianCloseMin) ||
      !ConfigureEASession(1, "LONDON", InpTradeLondon, InpLondonOpenHour, InpLondonOpenMin,
                         InpLondonCloseHour, InpLondonCloseMin) ||
      !ConfigureEASession(2, "NY", InpTradeNY, InpNYOpenHour, InpNYOpenMin,
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

void EnterTrades(const EASessionRange &range, const int direction, const MqlTick &tick)
{
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
   double price = buy ? tick.ask : tick.bid;
   double stop = StopPrice((buy ? range.low : range.high) +
                           (buy ? -1 : 1) * InpStopBufferPoints * _Point, tick_size, buy);
   double midpoint = StopPrice((range.high + range.low) / 2, tick_size, buy);
   double minimum_distance = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(stop <= 0 || midpoint <= 0 ||
      (buy ? tick.bid - stop : stop - tick.ask) < minimum_distance ||
      (buy ? midpoint - stop : stop - midpoint) < minimum_distance ||
      (buy ? tick.ask - midpoint : midpoint - tick.bid) < minimum_distance ||
      (buy ? stop >= tick.bid || midpoint >= tick.ask : stop <= tick.ask || midpoint <= tick.bid) ||
      range.next_session <= tick.time)
   {
      Print("Breakout pair skipped: range stop/midpoint violates broker price distance or has expired.");
      return;
   }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double market_volume, limit_volume;
   if(!EntryVolume(buy, price, stop, equity, true, market_volume) ||
      !EntryVolume(buy, midpoint, stop, equity, false, limit_volume))
      return;
   double limit = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);
   if(limit > 0 &&
      DirectionalExposure(buy) + market_volume + limit_volume > limit + 1e-8)
   {
      Print("Breakout pair skipped: combined volume exceeds broker directional limit.");
      return;
   }
   ENUM_ORDER_TYPE type = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double market_margin, limit_margin;
   if(!OrderCalcMargin(type, _Symbol, market_volume, price, market_margin) ||
      !OrderCalcMargin(type, _Symbol, limit_volume, midpoint, limit_margin) ||
      market_margin + limit_margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      Print("Breakout pair skipped: insufficient margin or margin calculation failed. Error: ", GetLastError());
      return;
   }
   string comment = "MSB HIGH " + g_sessions[range.session].name;
   bool sent = buy ? g_trade.Buy(market_volume, _Symbol, 0, stop, 0, comment) :
                     g_trade.Sell(market_volume, _Symbol, 0, stop, 0, comment);
   if(!TradeResult(sent, "High-risk breakout entry"))
   {
      Print("Midpoint entry not submitted because the market entry was not confirmed filled.");
      return;
   }
   Print(comment, " entry filled. Volume=", g_trade.ResultVolume(), ", SL=", stop);
   long expiry_mode = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   ENUM_ORDER_TYPE_TIME time_type = ORDER_TIME_SPECIFIED;
   datetime expiry = range.next_session;
   if((expiry_mode & SYMBOL_EXPIRATION_SPECIFIED) == 0)
   {
      if((expiry_mode & SYMBOL_EXPIRATION_GTC) == 0)
      {
         Print("Midpoint entry skipped: broker supports neither specified expiry nor GTC.");
         return;
      }
      time_type = ORDER_TIME_GTC;
      expiry = 0;
      Print("Midpoint uses terminal-side expiry; terminal must stay running and connected.");
   }
   comment = "MSB MID " + IntegerToString((long)range.next_session);
   g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   sent = buy ? g_trade.BuyLimit(limit_volume, midpoint, _Symbol, stop, 0,
                                 time_type, expiry, comment) :
                g_trade.SellLimit(limit_volume, midpoint, _Symbol, stop, 0,
                                  time_type, expiry, comment);
   uint code = g_trade.ResultRetcode();
   string result_description = g_trade.ResultRetcodeDescription();
   ulong order = g_trade.ResultOrder();
   if(!g_trade.SetTypeFillingBySymbol(_Symbol))
      Warn("Cannot restore immediate filling policy after midpoint submission.");
   if(!sent || (code != TRADE_RETCODE_PLACED && code != TRADE_RETCODE_DONE))
      Print("Midpoint limit failed; market position remains protected: ", code, " ",
            result_description);
   else
      Print("Medium-risk midpoint limit accepted: order=", order,
            ", price=", midpoint, ", volume=", limit_volume,
            ", expiry=", TimeToString(range.next_session, TIME_DATE | TIME_SECONDS));
}

void ExpireMidpointOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic ||
         (OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_BUY_LIMIT &&
          OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_SELL_LIMIT))
         continue;
      string comment = OrderGetString(ORDER_COMMENT);
      datetime expiry = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      if(expiry == 0 && StringFind(comment, "MSB MID ") == 0)
         expiry = (datetime)StringToInteger(StringSubstr(comment, 8));
      if(InpEnableEA && expiry <= 0)
      {
         Warn("Midpoint expiry is missing from broker history; cancellation required.");
         continue;
      }
      if((InpEnableEA && TimeTradeServer() < expiry) || !TradingAllowed())
         continue;
      bool sent = g_trade.OrderDelete(ticket);
      if(!sent || g_trade.ResultRetcode() != TRADE_RETCODE_DONE)
         Warn(StringFormat("Expired midpoint cancellation failed: %u %s",
                           g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      else
         Print(InpEnableEA ? "Expired midpoint order cancelled: " :
                            "Disabled EA midpoint order cancelled: ", ticket);
   }
}

void OnTimer()
{
   ExpireMidpointOrders();
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
         if(!ArmScaleOut(identifier, scaled > step * 1e-6 || profit_distance >= 2 * risk))
            continue;
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
      if(!TradingAllowed())
         continue;
      // Round toward profit so the remaining stop is never below entry for a buy.
      double breakeven = StopPrice(entry, tick_size, !buy);
      double stop = breakeven;
      double atr;
      if(ReadATR(atr))
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
         continue;
      g_ranges[i].evaluated = true;
      // Historical signals are consumed, never entered late or replayed after restart.
      if(confirmation == current_bar - PeriodSeconds(PERIOD_M5))
         EnterTrades(g_ranges[i], direction, tick);
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
   ExpireMidpointOrders();
   ManagePositions(tick);
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
      return;
   }
   if(current_bar > g_start_bar && current_bar != g_last_signal_bar)
      ProcessSignals(current_bar, tick);
}
