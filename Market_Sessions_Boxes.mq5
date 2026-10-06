//+------------------------------------------------------------------+
//| Market Sessions Boxes                                            |
//| Install in MQL5/Indicators and compile with MetaEditor (MT5).      |
//| Asian/London use GMT+2 winter times; NY uses UTC winter times.    |
//| London, New York and broker DST are calculated for each date.     |
//+------------------------------------------------------------------+
#property version   "1.01"
#property description "Asian, London and NY session ranges in broker server time."
#property indicator_chart_window
#property indicator_plots 0

#include <Canvas/Canvas.mqh>

enum BrokerDSTRule
{
   BROKER_DST_NONE,      // No daylight saving
   BROKER_DST_EUROPE,    // Last Sunday March/October, 01:00 UTC
   BROKER_DST_US,        // US Eastern: second Sunday March/first Sunday November
   BROKER_DST_AUSTRALIA, // First Sunday October/April, local 02:00/03:00
   BROKER_DST_NZ        // Last Sunday September/first Sunday April, local 02:00/03:00
};

input group "Broker Timezone"
input double        InpBrokerUTCOffset = 2.0; // Standard (winter) UTC offset in hours
input BrokerDSTRule InpBrokerDSTRule = BROKER_DST_NONE; // Fallback when automatic detection is disabled
input int           InpBrokerDSTMinutes = 60; // Broker clock advance during DST
input bool          InpDetectBrokerOffset = true; // Automatically measure offset and learn broker DST

input group "Asian Session (GMT+2 winter reference)"
input int   InpAsianOpenHour  = 0;
input int   InpAsianOpenMin   = 0;
input int   InpAsianCloseHour = 8;
input int   InpAsianCloseMin  = 0;
input int   InpAsianTransp   = 85; // Transparency: 0 = opaque, 100 = invisible fill

input group "London Session (GMT+2 winter reference)"
input int   InpLondonOpenHour  = 10;
input int   InpLondonOpenMin   = 0;
input int   InpLondonCloseHour = 14;
input int   InpLondonCloseMin  = 0;
input int   InpLondonTransp   = 85;

input group "NY Session (UTC winter reference)"
input int   InpNYOpenHour  = 14;
input int   InpNYOpenMin   = 30;
input int   InpNYCloseHour = 21;
input int   InpNYCloseMin  = 0;
input int   InpNYTransp   = 85;

input group "General Settings"
input bool InpShowLabels     = true; // Show session names
input bool InpShowTimeLabels = true; // Append opening time to session labels
input int  InpBoxWidth       = 1;    // Border width: 1-5 pixels
input int  InpDaysToShow     = 5;    // Calendar days including today: 1-30

struct SessionInfo
{
   string name;
   int    open_minutes;
   int    close_minutes;
   int    transparency;
};

struct SessionBox
{
   int      session;
   datetime open_time;
   datetime close_time;
   double   high;
   double   low;
   color    final_color;
   bool     evaluated;
   bool     range_loaded;
   datetime confirm_bar_time; // Open time of the M15 bar that confirmed the breakout
};

SessionInfo g_sessions[3];
SessionBox  g_boxes[];
CCanvas     g_canvas;
string      g_prefix = "MSB_UNINITIALIZED_";
long        g_chart;
int         g_width = 0;
int         g_height = 0;
int         g_box_count = 0;
datetime    g_day = 0;
datetime    g_last_update = 0;
datetime    g_last_bar = 0;
int         g_rsi_h1 = INVALID_HANDLE;
int         g_rsi_m15 = INVALID_HANDLE;
int         g_rsi_m5 = INVALID_HANDLE;
int         g_broker_base_minutes = 120;
BrokerDSTRule g_broker_rule = BROKER_DST_NONE;
int         g_broker_shift_minutes = 60;
bool        g_broker_ready = false;
bool        g_broker_verified = false;
string      g_offset_file;

struct BrokerObservation
{
   datetime utc;
   int      offset;
};
BrokerObservation g_observations[];

#define RSI_PERIOD 14

//+------------------------------------------------------------------+
//| Calendar rules use UTC instants, independent of the PC timezone.  |
//| occurrence = 0 selects the last Sunday, otherwise the nth Sunday. |
//+------------------------------------------------------------------+
datetime TransitionSunday(const int year, const int month,
                          const int occurrence, const int hour)
{
   MqlDateTime date = {};
   date.year = year;
   date.mon = (occurrence == 0 ? month + 1 : month);
   date.day = 1;
   if(date.mon == 13)
   {
      date.mon = 1;
      date.year++;
   }
   datetime day = StructToTime(date);
   if(occurrence == 0)
      day -= 86400;
   TimeToStruct(day, date);
   int delta = (occurrence == 0 ? -date.day_of_week :
                (7 - date.day_of_week) % 7 + (occurrence - 1) * 7);
   return day + delta * 86400 + hour * 3600;
}

bool IsDST(const datetime utc, const BrokerDSTRule rule,
           const int base_minutes, const int shift_minutes)
{
   if(rule == BROKER_DST_NONE)
      return false;
   MqlDateTime date;
   TimeToStruct(utc, date);
   datetime start, end;
   if(rule == BROKER_DST_EUROPE)
   {
      start = TransitionSunday(date.year, 3, 0, 1);
      end = TransitionSunday(date.year, 10, 0, 1);
   }
   else if(rule == BROKER_DST_US)
   {
      // Brokers using US dates commonly switch at the New York UTC instants.
      start = TransitionSunday(date.year, 3, 2, 7);
      end = TransitionSunday(date.year, 11, 1, 6);
   }
   else
   {
      start = TransitionSunday(date.year, rule == BROKER_DST_NZ ? 9 : 10,
                               rule == BROKER_DST_NZ ? 0 : 1, 2) - base_minutes * 60;
      end = TransitionSunday(date.year, 4, 1, 3) -
            (base_minutes + shift_minutes) * 60;
      return utc >= start || utc < end;
   }
   return utc >= start && utc < end;
}

int BrokerOffset(const datetime utc)
{
   if(InpDetectBrokerOffset && !MQLInfoInteger(MQL_TESTER) && !g_broker_verified)
   {
      // Until a rule is identified, use actual observations where available.
      for(int i = ArraySize(g_observations) - 1; i >= 0; i--)
        if(g_observations[i].utc <= utc)
           return g_observations[i].offset;
   }
   return g_broker_base_minutes +
          (IsDST(utc, g_broker_rule, g_broker_base_minutes, g_broker_shift_minutes) ?
           g_broker_shift_minutes : 0);
}

void LoadBrokerObservations()
{
   // A server-specific filename avoids sharing policies between brokers.
   string server = AccountInfoString(ACCOUNT_SERVER);
   uint hash = 2166136261;
   for(int i = 0; i < StringLen(server); i++)
      hash = (hash ^ StringGetCharacter(server, i)) * 16777619;
   g_offset_file = "MSB_Offsets_" + IntegerToString((long)hash) + ".csv";
   int file = FileOpen(g_offset_file, FILE_READ | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',');
   if(file == INVALID_HANDLE)
      return;
   datetime cutoff = TimeGMT() - 370 * 86400;
   while(!FileIsEnding(file))
   {
      string timestamp = FileReadString(file);
      if(FileIsEnding(file) || FileIsLineEnding(file))
         break; // An incomplete row must not consume the next row's timestamp.
      string value = FileReadString(file);
      datetime utc = (datetime)StringToInteger(timestamp);
      long raw_offset = StringToInteger(value);
      if(timestamp != IntegerToString((long)utc) ||
         value != IntegerToString(raw_offset) ||
         raw_offset < -840 || raw_offset > 840 || !FileIsLineEnding(file))
         break;
      int offset = (int)raw_offset;
      int count = ArraySize(g_observations);
      if(utc >= cutoff && utc <= TimeGMT() && offset >= -840 && offset <= 840 &&
        (count == 0 || utc > g_observations[count - 1].utc) &&
        ArrayResize(g_observations, count + 1) == count + 1)
      {
        g_observations[count].utc = utc;
        g_observations[count].offset = offset;
      }
   }
   FileClose(file);
}

void InferBrokerRule(const datetime now, const int current_offset)
{
   int minimum = current_offset, maximum = current_offset;
   bool winter = false, summer = false;
   for(int i = 0; i < ArraySize(g_observations); i++)
   {
      if(g_observations[i].utc < now - 370 * 86400)
        continue;
      minimum = MathMin(minimum, g_observations[i].offset);
      maximum = MathMax(maximum, g_observations[i].offset);
      MqlDateTime date;
      TimeToStruct(g_observations[i].utc, date);
      winter = winter || date.mon == 1;
      summer = summer || date.mon == 7;
   }
   g_broker_rule = BROKER_DST_NONE;
   g_broker_base_minutes = current_offset;
   g_broker_verified = (minimum == maximum && winter && summer);
   int shift = maximum - minimum;
   if(shift < 1 || shift > 120)
      return;

   int matches = 0;
   BrokerDSTRule selected = BROKER_DST_NONE;
   for(int candidate = BROKER_DST_EUROPE; candidate <= BROKER_DST_NZ; candidate++)
   {
      BrokerDSTRule rule = (BrokerDSTRule)candidate;
      bool fits = current_offset == minimum +
        (IsDST(now, rule, minimum, shift) ? shift : 0);
      for(int i = 0; i < ArraySize(g_observations) && fits; i++)
      {
        if(g_observations[i].utc < now - 370 * 86400)
           continue;
        int expected = minimum +
           (IsDST(g_observations[i].utc, rule, minimum, shift) ? shift : 0);
        fits = (expected == g_observations[i].offset);
      }
      if(fits)
      {
        matches++;
        selected = rule;
      }
   }
   // Winter/summer alone cannot distinguish Europe from US transition dates.
   if(matches == 1)
   {
      g_broker_rule = selected;
      g_broker_base_minutes = minimum;
      g_broker_shift_minutes = shift;
      g_broker_verified = true;
   }
}

void DetectBrokerOffset()
{
   int previous_base = g_broker_base_minutes;
   BrokerDSTRule previous_rule = g_broker_rule;
   int previous_shift = g_broker_shift_minutes;
   if(!InpDetectBrokerOffset || MQLInfoInteger(MQL_TESTER))
   {
      g_broker_base_minutes = (int)MathRound(InpBrokerUTCOffset * 60.0);
      g_broker_rule = InpBrokerDSTRule;
      g_broker_shift_minutes = InpBrokerDSTMinutes;
      g_broker_ready = true;
   }
   else
   {
      datetime utc = TimeGMT();
      datetime server = TimeTradeServer();
      // Do not learn from a disconnected terminal or stale weekend quotes.
      if(!TerminalInfoInteger(TERMINAL_CONNECTED) || utc <= 0 || server <= 0 ||
        MathAbs((double)(server - TimeCurrent())) > 180)
        return;
      int offset = (int)MathRound((double)(server - utc) / 60.0);
      if(offset < -840 || offset > 840)
        return;
      int count = ArraySize(g_observations);
      if(count == 0 || (utc > g_observations[count - 1].utc &&
        (utc / 86400 != g_observations[count - 1].utc / 86400 ||
         offset != g_observations[count - 1].offset)))
      {
        if(ArrayResize(g_observations, count + 1) == count + 1)
        {
           g_observations[count].utc = utc;
           g_observations[count].offset = offset;
           int file = FileOpen(g_offset_file, FILE_READ | FILE_WRITE | FILE_CSV |
                               FILE_ANSI | FILE_SHARE_READ, ',');
           if(file != INVALID_HANDLE)
           {
              FileSeek(file, 0, SEEK_END);
              FileWrite(file, (long)utc, offset);
              FileClose(file);
           }
        }
      }
      InferBrokerRule(utc, offset);
      g_broker_ready = true;
   }
   if(previous_base != g_broker_base_minutes || previous_rule != g_broker_rule ||
      previous_shift != g_broker_shift_minutes)
      g_day = 0; // Rebuild object keys if the detected timezone changes.
}

void DrawBrokerTimezone()
{
   string name = g_prefix + "Timezone_Label";
   if(ObjectFind(g_chart, name) < 0)
   {
      if(!ObjectCreate(g_chart, name, OBJ_LABEL, 0, 0, 0))
        return;
      ObjectSetInteger(g_chart, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(g_chart, name, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(g_chart, name, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(g_chart, name, OBJPROP_YDISTANCE, 40);
      ObjectSetInteger(g_chart, name, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(g_chart, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(g_chart, name, OBJPROP_HIDDEN, true);
   }
   string text = "Broker timezone: waiting for live quotes";
   if(g_broker_ready)
   {
      bool automatic = InpDetectBrokerOffset && !MQLInfoInteger(MQL_TESTER);
      int offset = BrokerOffset(automatic ? TimeGMT() : TimeCurrent());
      string rules[] = {"None", "Europe", "US", "Australia", "NZ"};
      text = StringFormat("Broker UTC%s%02d:%02d | DST: %s%s",
                         offset < 0 ? "-" : "+", (int)MathAbs(offset) / 60,
                         (int)MathAbs(offset) % 60,
                         automatic && !g_broker_verified ? "unverified" : rules[(int)g_broker_rule],
                         automatic ? " (auto)" : " (manual/tester)");
   }
   ObjectSetInteger(g_chart, name, OBJPROP_COLOR,
                   ChartGetInteger(g_chart, CHART_COLOR_FOREGROUND));
   ObjectSetString(g_chart, name, OBJPROP_TEXT, text);
}

datetime SessionServerTime(const datetime reference, const int session)
{
   // NY uses UTC winter hours; Asian/London retain their GMT+2 reference.
   datetime utc = reference - (session == 2 ? 0 : 2 * 3600);
   if(session != 0)
   {
      BrokerDSTRule rule = (session == 1 ? BROKER_DST_EUROPE : BROKER_DST_US);
      // Resolve local wall time: first occurrence at fall-back; normalize
      // nonexistent spring-forward times into the following hour.
      if(IsDST(utc - 3600, rule, 0, 60))
         utc -= 3600;
   }
   return utc + BrokerOffset(utc) * 60;
}

//+------------------------------------------------------------------+
//| Reject invalid inputs rather than silently changing session times.|
//| A close earlier than the open crosses midnight; equal is invalid. |
//+------------------------------------------------------------------+
bool ConfigureSession(const int index, const string name,
                      const int open_hour, const int open_minute,
                      const int close_hour, const int close_minute,
                      const int transparency)
{
   if(open_hour < 0 || open_hour > 23 || close_hour < 0 || close_hour > 23 ||
      open_minute < 0 || open_minute > 59 || close_minute < 0 || close_minute > 59 ||
      transparency < 0 || transparency > 100 ||
      (open_hour == close_hour && open_minute == close_minute))
   {
      Print("Invalid ", name, " settings: hours 0-23, minutes 0-59, ",
            "transparency 0-100, and different opening/closing times required.");
      return false;
   }
   g_sessions[index].name = name;
   g_sessions[index].open_minutes = open_hour * 60 + open_minute;
   g_sessions[index].close_minutes = close_hour * 60 + close_minute;
   g_sessions[index].transparency = transparency;
   return true;
}

int OnInit()
{
   g_chart = ChartID();
   if(!MathIsValidNumber(InpBrokerUTCOffset) ||
      InpBrokerUTCOffset < -14.0 || InpBrokerUTCOffset > 14.0 ||
      InpBrokerDSTMinutes < 1 || InpBrokerDSTMinutes > 120 ||
      InpBrokerDSTRule < BROKER_DST_NONE || InpBrokerDSTRule > BROKER_DST_NZ)
   {
      Print("Broker UTC offset must be -14 to +14 hours, DST advance 1-120 minutes, ",
            "and a supported DST rule is required.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpDaysToShow < 1 || InpDaysToShow > 30 || InpBoxWidth < 1 || InpBoxWidth > 5)
   {
      Print("Days to show must be 1-30 and border width must be 1-5.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!ConfigureSession(0, "ASIAN", InpAsianOpenHour, InpAsianOpenMin,
                        InpAsianCloseHour, InpAsianCloseMin, InpAsianTransp) ||
      !ConfigureSession(1, "LONDON", InpLondonOpenHour, InpLondonOpenMin,
                        InpLondonCloseHour, InpLondonCloseMin, InpLondonTransp) ||
      !ConfigureSession(2, "NY", InpNYOpenHour, InpNYOpenMin,
                        InpNYCloseHour, InpNYCloseMin, InpNYTransp))
      return INIT_PARAMETERS_INCORRECT;

   // Reserve a chart-local namespace so multiple copies never delete each other.
   int instance = 0;
   do
   {
      g_prefix = "MSB_" + IntegerToString(instance++) + "_";
   }
   while(InstanceObjectsExist(g_prefix));

   g_width = (int)ChartGetInteger(g_chart, CHART_WIDTH_IN_PIXELS);
   g_height = (int)ChartGetInteger(g_chart, CHART_HEIGHT_IN_PIXELS, 0);
   if(g_width <= 0 || g_height <= 0 ||
      !g_canvas.CreateBitmapLabel(g_chart, 0, g_prefix + "Canvas", 0, 0,
                                  g_width, g_height, COLOR_FORMAT_ARGB_NORMALIZE))
   {
      Print("Unable to create session canvas. Error: ", GetLastError());
      return INIT_FAILED;
   }
   ObjectSetInteger(g_chart, g_prefix + "Canvas", OBJPROP_BACK, true);
   ObjectSetInteger(g_chart, g_prefix + "Canvas", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(g_chart, g_prefix + "Canvas", OBJPROP_HIDDEN, true);
   // iRSI returns handles; values are read with CopyBuffer once calculated.
   g_rsi_h1 = iRSI(_Symbol, PERIOD_H1, RSI_PERIOD, PRICE_CLOSE);
   g_rsi_m15 = iRSI(_Symbol, PERIOD_M15, RSI_PERIOD, PRICE_CLOSE);
   g_rsi_m5 = iRSI(_Symbol, PERIOD_M5, RSI_PERIOD, PRICE_CLOSE);
   if(g_rsi_h1 == INVALID_HANDLE || g_rsi_m15 == INVALID_HANDLE || g_rsi_m5 == INVALID_HANDLE)
      Print("Unable to create RSI handles. Error: ", GetLastError());
   g_canvas.Erase(0);
   g_canvas.Update(false);
   if(ArrayResize(g_boxes, (InpDaysToShow + 3) * 3) < 0 || !EventSetTimer(60))
   {
      Print("Unable to initialize session updates. Error: ", GetLastError());
      return INIT_FAILED;
   }
   if(InpDetectBrokerOffset && !MQLInfoInteger(MQL_TESTER))
      LoadBrokerObservations();
   UpdateSessions();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   g_canvas.Destroy();
   if(g_rsi_h1 != INVALID_HANDLE)
      IndicatorRelease(g_rsi_h1);
   if(g_rsi_m15 != INVALID_HANDLE)
      IndicatorRelease(g_rsi_m15);
   if(g_rsi_m5 != INVALID_HANDLE)
      IndicatorRelease(g_rsi_m5);
   if(g_prefix != "")
   {
      ObjectsDeleteAll(g_chart, g_prefix + "Box_");
      ObjectsDeleteAll(g_chart, g_prefix + "Label_");
      ObjectsDeleteAll(g_chart, g_prefix + "ConfirmArrow_");
      ObjectDelete(g_chart, g_prefix + "RSI_Label");
      ObjectDelete(g_chart, g_prefix + "Timezone_Label");
      ObjectDelete(g_chart, g_prefix + "Canvas");
   }
   ChartRedraw(g_chart);
}

bool InstanceObjectsExist(const string prefix)
{
   for(int i = ObjectsTotal(g_chart) - 1; i >= 0; i--)
      if(StringFind(ObjectName(g_chart, i), prefix) == 0)
         return true;
   return false;
}

int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
{
   if(rates_total == 0)
      return 0;
   datetime bar_time = time[ArrayGetAsSeries(time) ? 0 : rates_total - 1];
   datetime now = TimeCurrent();
   if(prev_calculated == 0 || bar_time != g_last_bar ||
      now < g_last_update || now - g_last_update >= 60)
   {
      g_last_bar = bar_time;
      UpdateSessions();
   }
   else
   {
      // RSI uses the forming bar, so refresh the label on every tick.
      DrawRSILevels();
      ChartRedraw(g_chart);
   }
   return rates_total;
}

void OnTimer()
{
   // Also retries asynchronous M1/M15 history requests without waiting for a tick.
   UpdateSessions();
}

void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_CHART_CHANGE)
      RenderFills();
}

//+------------------------------------------------------------------+
//| M1 bars make the range independent of the displayed timeframe.    |
//| Include opens in [start, end), never the bar opening at the close. |
//| CopyRates may return -1 while history loads; the timer retries.    |
//+------------------------------------------------------------------+
bool SessionRange(const datetime start, const datetime end,
                  const datetime now, double &highest, double &lowest)
{
   if(start > now)
      return false;
   datetime stop = (now < end ? now : end - 1);
   MqlRates rates[];
   int count = CopyRates(_Symbol, PERIOD_M1, start, stop, rates);
   if(count <= 0)
      return false;
   highest = rates[0].high;
   lowest = rates[0].low;
   for(int i = 1; i < count; i++)
   {
      highest = MathMax(highest, rates[i].high);
      lowest = MathMin(lowest, rates[i].low);
   }
   return true;
}

//+------------------------------------------------------------------+
//| Monitor M15 candles after session close until breakout detected.  |
//| Check each M15 close: if > high (green) or < low (red), lock color.|
//| Use body close only; in-range closes do not trigger evaluation.   |
//+------------------------------------------------------------------+
void ConfirmBreak(SessionBox &box, const datetime now)
{
   int period = PeriodSeconds(PERIOD_M15);
   
   // Already evaluated, no more checks needed
   if(box.evaluated)
      return;
   
   // Session hasn't closed yet, no M15 to check
   if(now < box.close_time)
      return;
   
   // Get all M15 bars from session close onwards
   MqlRates rates[];
   int count = CopyRates(_Symbol, PERIOD_M15, box.close_time, now, rates);
   
   if(count <= 0)
      return;  // M15 data not available yet, retry next update
   
   // Check each M15 bar starting from the first one after/at session close
   for(int i = 0; i < count; i++)
   {
      // Skip bars that closed before session ended
      if(rates[i].time + period <= box.close_time)
         continue;
      
      // Only check completed M15 bars (not the current open bar)
      datetime bar_close_time = rates[i].time + period;
      if(bar_close_time > now)
         continue;  // Bar hasn't closed yet
      
      // Check body close for breakout (strictly greater or strictly less)
      if(rates[i].close > box.high)
      {
         box.final_color = clrGreen;
         box.confirm_bar_time = rates[i].time;
         box.evaluated = true;
         return;
      }
      else if(rates[i].close < box.low)
      {
         box.final_color = clrRed;
         box.confirm_bar_time = rates[i].time;
         box.evaluated = true;
         return;
      }
      // else: in-range close, keep checking subsequent candles
   }
}

//+------------------------------------------------------------------+
//| Keep date-specific objects in place, avoiding delete/create flicker.|
//| Extra reference dates cover timezone shifts and overnight sessions.|
//+------------------------------------------------------------------+
void UpdateSessions()
{
   DetectBrokerOffset();
   DrawBrokerTimezone();
   datetime now = TimeCurrent(); // Broker's latest quote time, not local/UTC time
   if(now <= 0 || !g_broker_ready)
      return;
   MqlDateTime date;
   if(!TimeToStruct(now, date))
      return;
   date.hour = 0;
   date.min = 0;
   date.sec = 0;
   datetime today = StructToTime(date);
   if(today != g_day)
   {
      ObjectsDeleteAll(g_chart, g_prefix + "Box_");
      ObjectsDeleteAll(g_chart, g_prefix + "Label_");
      ObjectsDeleteAll(g_chart, g_prefix + "ConfirmArrow_");
      g_day = today;
   }

   SessionBox previous_boxes[];
   int previous_count = g_box_count;
   if(previous_count > 0)
      ArrayCopy(previous_boxes, g_boxes, 0, 0, previous_count);
   g_box_count = 0;
   datetime oldest = today - (InpDaysToShow - 1) * 86400;
   for(int day = InpDaysToShow + 1; day >= -1; day--)
   {
      datetime midnight = today - day * 86400;
      for(int s = 0; s < 3; s++)
      {
         datetime reference_start = midnight + g_sessions[s].open_minutes * 60;
         datetime reference_end = midnight + g_sessions[s].close_minutes * 60;
         if(reference_end < reference_start)
            reference_end += 86400;
         datetime start = SessionServerTime(reference_start, s);
         datetime end = SessionServerTime(reference_end, s);
         if(end <= oldest || start > now || end <= start)
            continue;
         string key = IntegerToString(s) + "_" + IntegerToString((long)start);
         SessionBox box;
         box.session = s;
         box.open_time = start;
         box.close_time = end;
         box.high = 0;
         box.low = 0;
         box.final_color = clrGray;
         box.evaluated = false;
         box.range_loaded = false;
         box.confirm_bar_time = 0;
         
         // Check if box exists in previous state and restore it
         for(int i = 0; i < previous_count; i++)
         {
            if(previous_boxes[i].session == s && previous_boxes[i].open_time == start &&
               previous_boxes[i].close_time == end)
            {
               box = previous_boxes[i];
               break;
            }
         }
         
         // Only attempt to load M1 range if it hasn't been loaded yet
         if(!box.range_loaded)
         {
            if(!SessionRange(start, end, now, box.high, box.low))
            {
               // If session is in the past and we still can't load M1 data, mark as attempted
               // but keep the box if it's already been evaluated or is recent
               if(end < now - 86400)
               {
                  // Very old session, if no data loaded, delete it
                  ObjectDelete(g_chart, g_prefix + "Box_" + key);
                  ObjectDelete(g_chart, g_prefix + "Label_" + key);
                  continue;
               }
               // Recent session, keep it for next update
               g_boxes[g_box_count] = box;
               g_box_count++;
               continue;
            }
            box.range_loaded = true;
         }
         
         // Monitor for breakout on each M15 candle after session close
         ConfirmBreak(box, now);
         g_boxes[g_box_count] = box;
         g_box_count++;
         DrawObjects(key, s, start, end, box.high, box.low, box.final_color);
         DrawConfirmationArrow(box);
      }
   }
   g_last_update = now;
   DrawRSILevels();
   RenderFills();
}

//+------------------------------------------------------------------+
//| Mark the M15 candle whose close confirmed the breakout with a     |
//| small orange arrow: up below the low for buys, down above the     |
//| high for sells, with the tip touching the candle.                 |
//+------------------------------------------------------------------+
void DrawConfirmationArrow(const SessionBox &box)
{
   if(!box.evaluated || box.confirm_bar_time == 0)
      return;
   string name = g_prefix + "ConfirmArrow_" + IntegerToString((long)box.confirm_bar_time);
   if(ObjectFind(g_chart, name) >= 0)
      return;
   MqlRates bar[];
   if(CopyRates(_Symbol, PERIOD_M15, box.confirm_bar_time, 1, bar) <= 0 ||
      bar[0].time != box.confirm_bar_time)
      return; // M15 history not ready; retried on the next update
   bool buy = (box.final_color == clrGreen);
   ENUM_OBJECT type = (buy ? OBJ_ARROW_UP : OBJ_ARROW_DOWN);
   double price = (buy ? bar[0].low : bar[0].high);
   if(!ObjectCreate(g_chart, name, type, 0, bar[0].time, price))
   {
      Print("Unable to create confirmation arrow. Error: ", GetLastError());
      return;
   }
   ObjectSetInteger(g_chart, name, OBJPROP_ANCHOR, buy ? ANCHOR_TOP : ANCHOR_BOTTOM);
   ObjectSetInteger(g_chart, name, OBJPROP_COLOR, clrOrange);
   ObjectSetInteger(g_chart, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(g_chart, name, OBJPROP_BACK, false);
   ObjectSetInteger(g_chart, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(g_chart, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Latest RSI value of a handle, or a placeholder while calculating. |
//+------------------------------------------------------------------+
string RSIText(const int handle)
{
   double value[];
   if(handle == INVALID_HANDLE || BarsCalculated(handle) <= 0 ||
      CopyBuffer(handle, 0, 0, 1, value) <= 0)
      return "--";
   return DoubleToString(value[0], 2);
}

//+------------------------------------------------------------------+
//| Show H1, M15 and M5 RSI in the chart's top-right corner.          |
//+------------------------------------------------------------------+
void DrawRSILevels()
{
   string name = g_prefix + "RSI_Label";
   if(ObjectFind(g_chart, name) < 0)
   {
      if(!ObjectCreate(g_chart, name, OBJ_LABEL, 0, 0, 0))
      {
         Print("Unable to create RSI label. Error: ", GetLastError());
         return;
      }
      ObjectSetInteger(g_chart, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(g_chart, name, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(g_chart, name, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(g_chart, name, OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(g_chart, name, OBJPROP_FONTSIZE, 10);
      ObjectSetInteger(g_chart, name, OBJPROP_BACK, false);
      ObjectSetInteger(g_chart, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(g_chart, name, OBJPROP_HIDDEN, true);
   }
   // Foreground color stays readable on both light and dark chart themes.
   ObjectSetInteger(g_chart, name, OBJPROP_COLOR,
                    ChartGetInteger(g_chart, CHART_COLOR_FOREGROUND));
   ObjectSetString(g_chart, name, OBJPROP_TEXT,
                   "H1 RSI: " + RSIText(g_rsi_h1) +
                   " | M15 RSI: " + RSIText(g_rsi_m15) +
                   " | M5 RSI: " + RSIText(g_rsi_m5));
}

void DrawObjects(const string key, const int session,
                 const datetime start, const datetime end,
                 const double highest, const double lowest, const color box_color)
{
   string box = g_prefix + "Box_" + key;
   if(ObjectFind(g_chart, box) < 0)
   {
      if(!ObjectCreate(g_chart, box, OBJ_RECTANGLE, 0, start, highest, end, lowest))
      {
         Print("Unable to create session border. Error: ", GetLastError());
         return;
      }
      ObjectSetInteger(g_chart, box, OBJPROP_FILL, false);
      ObjectSetInteger(g_chart, box, OBJPROP_BACK, true);
      ObjectSetInteger(g_chart, box, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(g_chart, box, OBJPROP_HIDDEN, true);
      ObjectSetInteger(g_chart, box, OBJPROP_WIDTH, InpBoxWidth);
   }
   ObjectSetInteger(g_chart, box, OBJPROP_COLOR, box_color);
   ObjectMove(g_chart, box, 0, start, highest);
   ObjectMove(g_chart, box, 1, end, lowest);

   string label = g_prefix + "Label_" + key;
   if(!InpShowLabels)
      return;
   if(ObjectFind(g_chart, label) < 0)
   {
      if(!ObjectCreate(g_chart, label, OBJ_TEXT, 0, start, highest))
      {
         Print("Unable to create session label. Error: ", GetLastError());
         return;
      }
      ObjectSetInteger(g_chart, label, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(g_chart, label, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(g_chart, label, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(g_chart, label, OBJPROP_HIDDEN, true);
      string text = g_sessions[session].name;
      if(InpShowTimeLabels)
         text += " " + TimeToString(start, TIME_MINUTES);
      ObjectSetString(g_chart, label, OBJPROP_TEXT, text);
   }
   ObjectSetInteger(g_chart, label, OBJPROP_COLOR, box_color);
   ObjectMove(g_chart, label, 0, start, highest);
}

//+------------------------------------------------------------------+
//| OBJ_RECTANGLE ignores alpha: fills use the standard ARGB canvas.  |
//| Native objects retain exact time/price borders and label anchors. |
//| Reproject and clip fills on scrolling, zooming, or chart resizing.|
//+------------------------------------------------------------------+
void RenderFills()
{
   int width = (int)ChartGetInteger(g_chart, CHART_WIDTH_IN_PIXELS);
   int height = (int)ChartGetInteger(g_chart, CHART_HEIGHT_IN_PIXELS, 0);
   if(width <= 0 || height <= 0)
      return;
   if(width != g_width || height != g_height)
   {
      if(!g_canvas.Resize(width, height))
      {
         Print("Unable to resize session canvas. Error: ", GetLastError());
         return;
      }
      g_width = width;
      g_height = height;
   }
   g_canvas.Erase(0); // Fully transparent background
   for(int i = 0; i < g_box_count; i++)
   {
      int x1, y1, x2, y2;
      if(!ChartTimePriceToXY(g_chart, 0, g_boxes[i].open_time, g_boxes[i].high, x1, y1) ||
         !ChartTimePriceToXY(g_chart, 0, g_boxes[i].close_time, g_boxes[i].low, x2, y2))
         continue;
      int left = MathMax(0, MathMin(x1, x2));
      int right = MathMin(width - 1, MathMax(x1, x2));
      int top = MathMax(0, MathMin(y1, y2));
      int bottom = MathMin(height - 1, MathMax(y1, y2));
      if(left > right || top > bottom)
         continue;
      int s = g_boxes[i].session;
      uchar alpha = (uchar)MathRound(255.0 * (100 - g_sessions[s].transparency) / 100.0);
      g_canvas.FillRectangle(left, top, right, bottom,
                             ColorToARGB(g_boxes[i].final_color, alpha));
   }
   g_canvas.Update(false);
   ChartRedraw(g_chart);
}
