//+------------------------------------------------------------------+
//| Market Sessions Boxes                                            |
//| Install in MQL5/Indicators and compile with MetaEditor (MT5).      |
//| Times use the broker's server clock, assumed GMT+2 by default.    |
//| No UTC conversion or automatic daylight-saving adjustment occurs.|
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "Asian, London and NY session ranges in broker server time."
#property indicator_chart_window
#property indicator_plots 0

#include <Canvas/Canvas.mqh>
#include "EconomicCalendar.mqh"

input group "Asian Session (server time)"
input int   InpAsianOpenHour  = 0;
input int   InpAsianOpenMin   = 0;
input int   InpAsianCloseHour = 8;
input int   InpAsianCloseMin  = 0;
input int   InpAsianTransp   = 85; // Transparency: 0 = opaque, 100 = invisible fill

input group "London Session (server time)"
input int   InpLondonOpenHour  = 10;
input int   InpLondonOpenMin   = 0;
input int   InpLondonCloseHour = 14;
input int   InpLondonCloseMin  = 0;
input int   InpLondonTransp   = 85;

input group "NY Session (server time)"
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

input group "Economic Calendar (MT5 native)"
input bool InpShowEconomicEvents = true;
input bool InpEconomicAlerts = true; // Print upcoming/released events to the journal
input bool InpAutoBrokerUTCOffset = true;
input int  InpBrokerUTCOffsetMinutes = 120; // Used when automatic offset is disabled
input int  InpPostEventMinutes = 30; // Volatility window: 15-30 minutes

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
string      g_prefix;
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
EventInfo   g_events[];
datetime    g_calendar_success = 0;
bool        g_calendar_available = false;
int         g_event_page = 0;
int         g_event_pages = 1;

#define RSI_PERIOD 14

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
   if(InpPostEventMinutes < 15 || InpPostEventMinutes > 30 ||
      InpBrokerUTCOffsetMinutes < -840 || InpBrokerUTCOffsetMinutes > 840)
   {
      Print("Calendar post-event window must be 15-30 minutes; UTC offset -840 to 840.");
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

   g_chart = ChartID();
   // Reserve a chart-local namespace so multiple copies never delete each other.
   int instance = 0;
   do
   {
      g_prefix = "MSB_" + IntegerToString(instance++) + "_";
   }
   while(ObjectFind(g_chart, g_prefix + "Canvas") >= 0);

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
   if(ArrayResize(g_boxes, (InpDaysToShow + 1) * 3) < 0 || !EventSetTimer(60))
   {
      Print("Unable to initialize session updates. Error: ", GetLastError());
      return INIT_FAILED;
   }
   UpdateEconomicEvents();
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
   // An empty prefix would delete unrelated objects after invalid inputs.
   // Removes boxes, labels, confirmation arrows and the RSI label of this instance.
   if(g_prefix != "")
   {
      ObjectsDeleteAll(g_chart, g_prefix + "ConfirmArrow_");
      ObjectsDeleteAll(g_chart, g_prefix);
   }
   ChartRedraw(g_chart);
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
   UpdateEconomicEvents();
   UpdateSessions();
}

void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_CHART_CHANGE)
   {
      DrawEconomicEvents();
      RenderFills();
   }
   if(id == CHARTEVENT_OBJECT_CLICK &&
      (sparam == g_prefix + "Event_Next" || sparam == g_prefix + "Event_Prev"))
   {
      g_event_page = (g_event_page + (sparam == g_prefix + "Event_Next" ? 1 : -1)
                      + g_event_pages) % g_event_pages;
      ObjectSetInteger(g_chart, sparam, OBJPROP_STATE, false);
      DrawEconomicEvents();
      ChartRedraw(g_chart);
   }
}

// Calendar times are UTC, independent of chart bars and the broker's last tick.
int CalendarBrokerOffset()
{
   if(!InpAutoBrokerUTCOffset)
      return InpBrokerUTCOffsetMinutes * 60;
   return (int)(MathRound((double)(TimeTradeServer() - TimeGMT()) / 60.0) * 60);
}

string CalendarEventValue(const string value, const string unit)
{
   if(CalendarMissing(value))
      return "--";
   if((unit == "percent" || unit == "%") && StringFind(value, "%") < 0)
      return value + "%";
   if((unit == "K" || unit == "M" || unit == "B" || unit == "T") &&
      StringFind(value, unit) < 0)
      return value + unit;
   return value;
}

string CalendarSurprise(const EventInfo &event)
{
   double actual, forecast;
   if(!CalendarNumber(event.actual, actual) || !CalendarNumber(event.forecast, forecast))
      return "--";
   double delta = actual - forecast;
   string result = (delta > 0 ? "+" : "") + DoubleToString(delta, 2);
   if(event.unit == "percent" || event.unit == "%" || StringFind(event.actual, "%") >= 0)
      result += " pp";
   else if((event.unit == "K" || event.unit == "M" || event.unit == "B" || event.unit == "T") &&
           StringFind(event.actual, event.unit) < 0 && StringFind(event.forecast, event.unit) < 0)
      result += event.unit;
   if(forecast != 0)
   {
      double relative = delta / MathAbs(forecast) * 100.0;
      result += " (" + (relative > 0 ? "+" : "") + DoubleToString(relative, 2) + "%)";
   }
   return result;
}

void UpdateEconomicEvents()
{
   if(!InpShowEconomicEvents)
      return;
   EventInfo incoming[];
   datetime success;
   bool available;
   if(ReadNativeCalendar(incoming, success, available))
   {
      for(int i = 0; i < ArraySize(incoming); i++)
         for(int j = 0; j < ArraySize(g_events); j++)
            if(incoming[i].name == g_events[j].name &&
               incoming[i].release_time == g_events[j].release_time)
            {
               incoming[i].hour_alerted = g_events[j].hour_alerted;
               incoming[i].release_alerted = g_events[j].release_alerted;
               break;
            }
      if(CalendarCopy(g_events, incoming))
      {
         g_calendar_success = success;
         g_calendar_available = available;
      }
      else
         g_calendar_available = false;
   }
   else
      g_calendar_available = false;
   datetime now = TimeGMT();
   int retained = 0;
   for(int i = 0; i < ArraySize(g_events); i++)
   {
      if(g_events[i].release_time < now - 86400)
         continue;
      g_events[i].gold_impact_direction = CalendarGoldDirection(g_events[i]);
      long remaining = g_events[i].release_time - now;
      if(InpEconomicAlerts && remaining > 0 && remaining <= 3600 &&
         !g_events[i].hour_alerted)
      {
         Print("Economic calendar: ", g_events[i].name, " in ",
               (remaining + 59) / 60, " min; forecast ",
               CalendarEventValue(g_events[i].forecast, g_events[i].unit));
         g_events[i].hour_alerted = true;
      }
      if(InpEconomicAlerts && remaining <= 0 && g_events[i].actual != "" &&
         !g_events[i].release_alerted)
      {
         Print("Economic calendar released: ", g_events[i].name, "; actual ",
               CalendarEventValue(g_events[i].actual, g_events[i].unit),
               "; surprise ", CalendarSurprise(g_events[i]));
         g_events[i].release_alerted = true;
      }
      g_events[retained++] = g_events[i];
   }
   ArrayResize(g_events, retained);
   DrawEconomicEvents();
}

void CalendarLabel(const string name, const string text, const int y, const color ink)
{
   if(ObjectFind(g_chart, name) < 0)
   {
      if(!ObjectCreate(g_chart, name, OBJ_LABEL, 0, 0, 0))
         return;
      ObjectSetInteger(g_chart, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(g_chart, name, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(g_chart, name, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(g_chart, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(g_chart, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(g_chart, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(g_chart, name, OBJPROP_COLOR, ink);
   ObjectSetString(g_chart, name, OBJPROP_TEXT, text);
}

void DrawEconomicEvents()
{
   if(!InpShowEconomicEvents)
      return;
   datetime now = TimeGMT();
   int height = (int)ChartGetInteger(g_chart, CHART_HEIGHT_IN_PIXELS, 0);
   int rows = MathMax(1, (height - 110) / 40);
   int count = ArraySize(g_events);
   g_event_pages = MathMax(1, (count + rows - 1) / rows);
   g_event_page = MathMin(g_event_page, g_event_pages - 1);
   string status = "Economic calendar";
   if(!g_calendar_available || g_calendar_success == 0 || now - g_calendar_success > 7200)
      status += " | MT5 calendar unavailable/stale" + (count > 0 ? " (last known data)" : " - check MT5 Calendar tab");
   else if(count == 0)
      status += " | No tracked USD events in next 14 days";
   if(g_calendar_success > 0)
      status += " | Updated " + TimeToString(g_calendar_success, TIME_DATE | TIME_MINUTES) + " UTC";
   status += " | Page " + IntegerToString(g_event_page + 1) + "/" + IntegerToString(g_event_pages);
   CalendarLabel(g_prefix + "Event_Status", status, 45,
                 (color)ChartGetInteger(g_chart, CHART_COLOR_FOREGROUND));
   // Only remove unused row objects; keep active labels in place to avoid flicker.
   int used = MathMin(rows, count - g_event_page * rows);
   for(int i = ObjectsTotal(g_chart) - 1; i >= 0; i--)
   {
      string name = ObjectName(g_chart, i);
      if(StringFind(name, g_prefix + "Event_Row_") == 0 &&
         (int)StringToInteger(StringSubstr(name, StringLen(g_prefix + "Event_Row_"))) >= used)
         ObjectDelete(g_chart, name);
   }
   for(int row = 0; row < used; row++)
   {
      EventInfo event = g_events[g_event_page * rows + row];
      color ink = (event.impact_level == 3 ? clrRed : event.impact_level == 2 ? clrGoldenrod : clrGreen);
      string impact = (event.impact_level == 3 ? "🔴 HIGH" : event.impact_level == 2 ? "🟡 MED" : "🟢 LOW");
      string text = event.name + " | Forecast: " + CalendarEventValue(event.forecast, event.unit);
      if(event.release_time <= now && event.actual != "")
         text += " | Actual: " + CalendarEventValue(event.actual, event.unit) +
                 " | Surprise: " + CalendarSurprise(event);
      else
         text += " | Time: " + (event.release_time > now ?
                 IntegerToString((event.release_time - now + 59) / 60) + " min" : "Released, awaiting actual");
      text += " | Impact: " + impact;
      string key = g_prefix + "Event_Row_" + IntegerToString(row);
      CalendarLabel(key, text, 70 + row * 40, ink);
      int bias = event.gold_impact_direction;
      CalendarLabel(key + "_Bias",
                    TimeToString(event.release_time, TIME_DATE | TIME_MINUTES) + " UTC | Gold: " +
                    (bias < 0 ? "↓ Bearish" : bias > 0 ? "↑ Bullish" : "→ Neutral"),
                    88 + row * 40, bias < 0 ? clrRed : bias > 0 ? clrGreen :
                    (color)ChartGetInteger(g_chart, CHART_COLOR_FOREGROUND));
   }
   for(int i = 0; i < 2; i++)
   {
      string name = g_prefix + (i == 0 ? "Event_Prev" : "Event_Next");
      if(g_event_pages == 1)
      {
         ObjectDelete(g_chart, name);
         continue;
      }
      if(ObjectFind(g_chart, name) < 0)
         ObjectCreate(g_chart, name, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(g_chart, name, OBJPROP_XDISTANCE, 10 + i * 80);
      ObjectSetInteger(g_chart, name, OBJPROP_YDISTANCE, 70 + used * 40);
      ObjectSetInteger(g_chart, name, OBJPROP_XSIZE, 75);
      ObjectSetInteger(g_chart, name, OBJPROP_YSIZE, 20);
      ObjectSetInteger(g_chart, name, OBJPROP_HIDDEN, true);
      ObjectSetString(g_chart, name, OBJPROP_TEXT, i == 0 ? "Previous" : "Next");
   }
}

// Interpolate within a bar so 15/30-minute zones still have width on H1 charts.
bool CalendarTimeX(const datetime time, const double price, int &x)
{
   int shift = iBarShift(_Symbol, _Period, time, false);
   if(shift < 0)
      return false;
   datetime start = iTime(_Symbol, _Period, shift);
   datetime end = (shift > 0 ? iTime(_Symbol, _Period, shift - 1) :
                   start + PeriodSeconds(_Period));
   int x1, x2, y;
   if(end <= start || !ChartTimePriceToXY(g_chart, 0, start, price, x1, y) ||
      !ChartTimePriceToXY(g_chart, 0, end, price, x2, y))
      return false;
   x = (int)MathRound(x1 + (double)(time - start) / (end - start) * (x2 - x1));
   return true;
}

void RenderEconomicZones(const int width, const int height)
{
   if(!InpShowEconomicEvents)
      return;
   int offset = CalendarBrokerOffset();
   double price = ChartGetDouble(g_chart, CHART_PRICE_MAX, 0);
   for(int i = 0; i < ArraySize(g_events); i++)
   {
      datetime release = g_events[i].release_time + offset;
      int before, at, after;
      if(!CalendarTimeX(release - 1800, price, before) ||
         !CalendarTimeX(release, price, at) ||
         !CalendarTimeX(release + InpPostEventMinutes * 60, price, after))
         continue;
      int left = MathMax(0, before), right = MathMin(width - 1, at);
      if(left <= right)
         g_canvas.FillRectangle(left, 0, right, height - 1, ColorToARGB(clrLightGray, 22));
      left = MathMax(0, at);
      right = MathMin(width - 1, after);
      if(left <= right)
         g_canvas.FillRectangle(left, 0, right, height - 1, ColorToARGB(clrGold, 32));
   }
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
//| The extra previous day retains overnight sessions on the first day.|
//+------------------------------------------------------------------+
void UpdateSessions()
{
   datetime now = TimeCurrent(); // Broker's latest quote time, not local/UTC time
   if(now <= 0)
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
   for(int day = InpDaysToShow; day >= 0; day--)
   {
      datetime midnight = today - day * 86400;
      for(int s = 0; s < 3; s++)
      {
         datetime start = midnight + g_sessions[s].open_minutes * 60;
         datetime end = midnight + g_sessions[s].close_minutes * 60;
         if(end < start)
            end += 86400;
         if(end <= oldest)
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
            if(previous_boxes[i].session == s && previous_boxes[i].open_time == start)
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
   RenderEconomicZones(width, height);
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
