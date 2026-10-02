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

input group "Asian Session (server time)"
input int   InpAsianOpenHour  = 0;
input int   InpAsianOpenMin   = 0;
input int   InpAsianCloseHour = 8;
input int   InpAsianCloseMin  = 0;
input color InpAsianColor    = clrDodgerBlue;
input int   InpAsianTransp   = 85; // Transparency: 0 = opaque, 100 = invisible fill

input group "London Session (server time)"
input int   InpLondonOpenHour  = 10;
input int   InpLondonOpenMin   = 0;
input int   InpLondonCloseHour = 14;
input int   InpLondonCloseMin  = 0;
input color InpLondonColor    = clrLimeGreen;
input int   InpLondonTransp   = 85;

input group "NY Session (server time)"
input int   InpNYOpenHour  = 14;
input int   InpNYOpenMin   = 30;
input int   InpNYCloseHour = 21;
input int   InpNYCloseMin  = 0;
input color InpNYColor    = clrOrangeRed;
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
   color  box_color;
   int    transparency;
};

struct SessionBox
{
   int      session;
   datetime open_time;
   datetime close_time;
   double   high;
   double   low;
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

//+------------------------------------------------------------------+
//| Reject invalid inputs rather than silently changing session times.|
//| A close earlier than the open crosses midnight; equal is invalid. |
//+------------------------------------------------------------------+
bool ConfigureSession(const int index, const string name,
                      const int open_hour, const int open_minute,
                      const int close_hour, const int close_minute,
                      const color box_color, const int transparency)
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
   g_sessions[index].box_color = box_color;
   g_sessions[index].transparency = transparency;
   return true;
}

int OnInit()
{
   if(InpDaysToShow < 1 || InpDaysToShow > 30 || InpBoxWidth < 1 || InpBoxWidth > 5)
   {
      Print("Days to show must be 1-30 and border width must be 1-5.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!ConfigureSession(0, "ASIAN", InpAsianOpenHour, InpAsianOpenMin,
                        InpAsianCloseHour, InpAsianCloseMin, InpAsianColor, InpAsianTransp) ||
      !ConfigureSession(1, "LONDON", InpLondonOpenHour, InpLondonOpenMin,
                        InpLondonCloseHour, InpLondonCloseMin, InpLondonColor, InpLondonTransp) ||
      !ConfigureSession(2, "NY", InpNYOpenHour, InpNYOpenMin,
                        InpNYCloseHour, InpNYCloseMin, InpNYColor, InpNYTransp))
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
   g_canvas.Erase(0);
   g_canvas.Update(false);
   if(ArrayResize(g_boxes, (InpDaysToShow + 1) * 3) < 0 || !EventSetTimer(60))
   {
      Print("Unable to initialize session updates. Error: ", GetLastError());
      return INIT_FAILED;
   }
   UpdateSessions();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   g_canvas.Destroy();
   // An empty prefix would delete unrelated objects after invalid inputs.
   if(g_prefix != "")
      ObjectsDeleteAll(g_chart, g_prefix);
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
   return rates_total;
}

void OnTimer()
{
   // Also retries asynchronous M1 history requests without waiting for a tick.
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
      g_day = today;
   }

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
         double highest, lowest;
         if(!SessionRange(start, end, now, highest, lowest))
         {
            ObjectDelete(g_chart, g_prefix + "Box_" + key);
            ObjectDelete(g_chart, g_prefix + "Label_" + key);
            continue;
         }
         g_boxes[g_box_count].session = s;
         g_boxes[g_box_count].open_time = start;
         g_boxes[g_box_count].close_time = end;
         g_boxes[g_box_count].high = highest;
         g_boxes[g_box_count].low = lowest;
         g_box_count++;
         DrawObjects(key, s, start, end, highest, lowest);
      }
   }
   g_last_update = now;
   RenderFills();
}

void DrawObjects(const string key, const int session,
                 const datetime start, const datetime end,
                 const double highest, const double lowest)
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
      ObjectSetInteger(g_chart, box, OBJPROP_COLOR, g_sessions[session].box_color);
      ObjectSetInteger(g_chart, box, OBJPROP_WIDTH, InpBoxWidth);
   }
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
      ObjectSetInteger(g_chart, label, OBJPROP_COLOR, g_sessions[session].box_color);
      ObjectSetInteger(g_chart, label, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(g_chart, label, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(g_chart, label, OBJPROP_HIDDEN, true);
      string text = g_sessions[session].name;
      if(InpShowTimeLabels)
         text += " " + TimeToString(start, TIME_MINUTES);
      ObjectSetString(g_chart, label, OBJPROP_TEXT, text);
   }
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
                             ColorToARGB(g_sessions[s].box_color, alpha));
   }
   g_canvas.Update(false);
   ChartRedraw(g_chart);
}
