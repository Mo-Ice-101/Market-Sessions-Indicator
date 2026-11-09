#ifndef MARKET_SESSIONS_EA_VISUALS_MQH
#define MARKET_SESSIONS_EA_VISUALS_MQH

#include <Canvas/Canvas.mqh>

// Compiled into the EA: no indicator handle, inputs or independent schedule.
struct EABoxView
{
   datetime start;
   datetime end;
   double high;
   double low;
   color shade;
};

CCanvas g_ea_canvas;
EABoxView g_ea_box_views[];
string g_ea_visual_prefix = "";
bool g_ea_visuals_ready = false;
int g_ea_visual_width = 0;
int g_ea_visual_height = 0;
int g_ea_rsi[3] = {INVALID_HANDLE, INVALID_HANDLE, INVALID_HANDLE};
datetime g_ea_visual_update = 0;
datetime g_ea_visual_day = 0;
datetime g_ea_visual_warning = 0;

void WarnEAVisual(const string message)
{
   datetime now = TimeCurrent();
   if(g_ea_visual_warning == 0 || now < g_ea_visual_warning ||
      now - g_ea_visual_warning >= 60)
   {
      Print("Market Sessions EA [boxes] ", message);
      g_ea_visual_warning = now;
   }
}

bool InitEAVisuals()
{
   // Remove known legacy copies so their M5 signals cannot cover the EA's boxes.
   for(int i = ChartIndicatorsTotal(0, 0) - 1; i >= 0; i--)
   {
      string name = ChartIndicatorName(0, 0, i);
      if(name != "Market Sessions Boxes" && StringFind(name, "MSB EA ") != 0)
         continue;
      if(!ChartIndicatorDelete(0, 0, name))
      {
         Print("Cannot remove legacy boxes indicator '", name, "'. Error: ", GetLastError());
         return false;
      }
      Print("Removed legacy boxes indicator '", name, "'; the EA now owns its drawings.");
   }
   if(!InpShowSessionBoxes ||
      (MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)))
      return true;
   g_ea_visual_prefix = StringFormat("MSEA_%I64u_", GetMicrosecondCount());
   g_ea_visual_width = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   g_ea_visual_height = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   if(g_ea_visual_width <= 0 || g_ea_visual_height <= 0 ||
      !g_ea_canvas.CreateBitmapLabel(0, 0, g_ea_visual_prefix + "Canvas", 0, 0,
         g_ea_visual_width, g_ea_visual_height, COLOR_FORMAT_ARGB_NORMALIZE))
   {
      Print("Cannot initialize built-in session canvas. Error: ", GetLastError());
      return false;
   }
   ObjectSetInteger(0, g_ea_visual_prefix + "Canvas", OBJPROP_BACK, true);
   ObjectSetInteger(0, g_ea_visual_prefix + "Canvas", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, g_ea_visual_prefix + "Canvas", OBJPROP_HIDDEN, true);
   g_ea_rsi[0] = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   g_ea_rsi[1] = iRSI(_Symbol, PERIOD_M15, 14, PRICE_CLOSE);
   g_ea_rsi[2] = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
   for(int i = 0; i < 3; i++)
      if(g_ea_rsi[i] == INVALID_HANDLE)
      {
         Print("Cannot initialize built-in RSI display. Error: ", GetLastError());
         return false;
      }
   g_ea_canvas.Erase(0);
   g_ea_canvas.Update(false);
   g_ea_visuals_ready = true;
   return true;
}

void DestroyEAVisuals()
{
   g_ea_visuals_ready = false;
   g_ea_canvas.Destroy();
   for(int i = 0; i < 3; i++)
      if(g_ea_rsi[i] != INVALID_HANDLE)
      {
         IndicatorRelease(g_ea_rsi[i]);
         g_ea_rsi[i] = INVALID_HANDLE;
      }
   if(g_ea_visual_prefix != "")
      ObjectsDeleteAll(0, g_ea_visual_prefix);
   ChartRedraw();
}

bool EAVisualObject(const string name, const ENUM_OBJECT type,
                    const datetime start = 0, const double price = 0,
                    const datetime end = 0, const double other_price = 0)
{
   if(ObjectFind(0, name) >= 0)
      return true;
   if(!ObjectCreate(0, name, type, 0, start, price, end, other_price))
   {
      WarnEAVisual("Cannot create built-in drawing '" + name + "'. Error: " +
           IntegerToString(GetLastError()));
      return false;
   }
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
}

void EAVisualLabel(const string suffix, const string text, const int y)
{
   string name = g_ea_visual_prefix + suffix;
   if(!EAVisualObject(name, OBJ_LABEL))
      return;
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, name, OBJPROP_COLOR, ChartGetInteger(0, CHART_COLOR_FOREGROUND));
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void DrawEAVisualStatus()
{
   string values[3];
   for(int i = 0; i < 3; i++)
   {
      double value[];
      values[i] = "--";
      if(BarsCalculated(g_ea_rsi[i]) > 0 && CopyBuffer(g_ea_rsi[i], 0, 0, 1, value) == 1)
         values[i] = DoubleToString(value[0], 2);
   }
   int line = (int)MathCeil(14.0 * TerminalInfoInteger(TERMINAL_SCREEN_DPI) / 72.0) + 6;
   EAVisualLabel("RSI", "H1 RSI: " + values[0] + " | M15 RSI: " + values[1] +
                 " | M5 RSI: " + values[2], 20);
   EAVisualLabel("Timezone", StringFormat("EA 1.10 | Broker standard UTC%+.2f | DST rule=%d",
                 InpBrokerUTCOffset, (int)InpBrokerDSTRule), 20 + line);
   string status = "";
   for(int s = 0; s < 3; s++)
      status += (s == 0 ? "" : " | ") + g_sessions[s].name + " " +
                EnumToString(g_sessions[s].break_timeframe) +
                (g_sessions[s].enabled ? "" : " (entries off)");
   EAVisualLabel("Timeframes", status, 20 + 2 * line);
}

void DrawEABox(const EASessionRange &range, const datetime end, const color shade,
               const datetime confirmation, const int direction)
{
   string key = g_ea_visual_prefix + "Range_" + IntegerToString(range.session) + "_" +
                IntegerToString((long)range.start);
   string border = key + "_Box";
   if(EAVisualObject(border, OBJ_RECTANGLE, range.start, range.high, end, range.low))
   {
      ObjectSetInteger(0, border, OBJPROP_FILL, false);
      ObjectSetInteger(0, border, OBJPROP_BACK, true);
      ObjectSetInteger(0, border, OBJPROP_COLOR, shade);
      ObjectMove(0, border, 0, range.start, range.high);
      ObjectMove(0, border, 1, end, range.low);
   }
   string label = key + "_Label";
   if(EAVisualObject(label, OBJ_TEXT, range.start, range.high))
   {
      ObjectSetInteger(0, label, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, label, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, label, OBJPROP_COLOR, shade);
      ObjectSetString(0, label, OBJPROP_TEXT, g_sessions[range.session].name + " " +
         TimeToString(range.start, TIME_MINUTES) + " " +
         EnumToString(g_sessions[range.session].break_timeframe));
      ObjectSetString(0, label, OBJPROP_TOOLTIP,
         "Opening M15 range; color and arrow mark a confirmed breakout, not an order fill.");
   }
   double prices[3];
   prices[0] = range.high;
   prices[1] = (range.high + range.low) / 2;
   prices[2] = range.low;
   for(int i = 0; i < 3; i++)
   {
      string level = key + "_Level_" + IntegerToString(i);
      if(!EAVisualObject(level, OBJ_TREND, range.start, prices[i], range.next_session, prices[i]))
         continue;
      ObjectSetInteger(0, level, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, level, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, level, OBJPROP_COLOR, shade);
      ObjectSetInteger(0, level, OBJPROP_STYLE, i == 1 ? STYLE_DOT : STYLE_SOLID);
      ObjectMove(0, level, 0, range.start, prices[i]);
      ObjectMove(0, level, 1, range.next_session, prices[i]);
   }
   if(direction == 0)
      return;
   string arrow = key + "_Arrow";
   if(ObjectFind(0, arrow) >= 0)
      return;
   MqlRates bar[];
   if(CopyRates(_Symbol, g_sessions[range.session].break_timeframe, confirmation, 1, bar) != 1 ||
      bar[0].time != confirmation)
   {
      WarnEAVisual("Confirmation candle unavailable for built-in arrow; retrying.");
      return;
   }
   bool buy = direction > 0;
   if(EAVisualObject(arrow, buy ? OBJ_ARROW_UP : OBJ_ARROW_DOWN,
                     confirmation, buy ? bar[0].low : bar[0].high))
   {
      ObjectSetInteger(0, arrow, OBJPROP_ANCHOR, buy ? ANCHOR_TOP : ANCHOR_BOTTOM);
      ObjectSetInteger(0, arrow, OBJPROP_COLOR, clrOrange);
      ObjectSetString(0, arrow, OBJPROP_TOOLTIP,
         "Confirmed " + EnumToString(g_sessions[range.session].break_timeframe) +
         " breakout; not proof of an executed trade.");
   }
}

void UpdateEAVisuals(const datetime now)
{
   if(!g_ea_visuals_ready || now <= 0 ||
      (now >= g_ea_visual_update && now / 5 == g_ea_visual_update / 5))
      return;
   if(!RebuildRanges(now))
      return;
   if(g_ea_visual_day != g_day)
   {
      ObjectsDeleteAll(0, g_ea_visual_prefix + "Range_");
      g_ea_visual_day = g_day;
   }
   if(ArrayResize(g_ea_box_views, ArraySize(g_ranges)) != ArraySize(g_ranges))
   {
      WarnEAVisual("Cannot allocate built-in session drawings; retrying.");
      return;
   }
   int count = 0;
   for(int i = 0; i < ArraySize(g_ranges); i++)
   {
      EASessionRange range = g_ranges[i];
      if(now < range.end)
         continue;
      // A local snapshot cannot consume or mark an EA entry as evaluated.
      if(!range.loaded && !LoadOpeningRange(_Symbol, range.start, now, range.high, range.low))
      {
         WarnEAVisual("Opening M15 history unavailable for built-in boxes; retrying.");
         continue;
      }
      datetime confirmation = 0;
      int direction = 0;
      datetime end = now < range.next_session ? now : range.next_session;
      ENUM_TIMEFRAMES timeframe = g_sessions[range.session].break_timeframe;
      if(now >= range.end + PeriodSeconds(timeframe))
      {
         MqlRates rates[];
         if(!ReadRangeBreak(range, now, rates, confirmation, direction))
            WarnEAVisual("Confirmation history unavailable for built-in boxes; retrying.");
      }
      color shade = direction > 0 ? clrGreen : (direction < 0 ? clrRed : clrGray);
      if(direction != 0)
         end = confirmation + PeriodSeconds(timeframe);
      DrawEABox(range, end, shade, confirmation, direction);
      g_ea_box_views[count].start = range.start;
      g_ea_box_views[count].end = end;
      g_ea_box_views[count].high = range.high;
      g_ea_box_views[count].low = range.low;
      g_ea_box_views[count].shade = shade;
      count++;
   }
   ArrayResize(g_ea_box_views, count);
   DrawEAVisualStatus();
   g_ea_visual_update = now;
   RenderEAVisualFills();
}

void RenderEAVisualFills()
{
   int width = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int height = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   if(width <= 0 || height <= 0)
      return;
   if(width != g_ea_visual_width || height != g_ea_visual_height)
   {
      if(!g_ea_canvas.Resize(width, height))
      {
         WarnEAVisual("Cannot resize built-in session canvas. Error: " + IntegerToString(GetLastError()));
         return;
      }
      g_ea_visual_width = width;
      g_ea_visual_height = height;
   }
   g_ea_canvas.Erase(0);
   for(int i = 0; i < ArraySize(g_ea_box_views); i++)
   {
      int x1, y1, x2, y2;
      if(!ChartTimePriceToXY(0, 0, g_ea_box_views[i].start, g_ea_box_views[i].high, x1, y1) ||
         !ChartTimePriceToXY(0, 0, g_ea_box_views[i].end, g_ea_box_views[i].low, x2, y2))
         continue;
      int left = MathMax(0, MathMin(x1, x2));
      int right = MathMin(width - 1, MathMax(x1, x2));
      int top = MathMax(0, MathMin(y1, y2));
      int bottom = MathMin(height - 1, MathMax(y1, y2));
      if(left > right || top > bottom)
         continue;
      uchar alpha = (uchar)MathRound(255.0 * (100 - InpBoxTransparency) / 100.0);
      g_ea_canvas.FillRectangle(left, top, right, bottom,
         ColorToARGB(g_ea_box_views[i].shade, alpha));
   }
   g_ea_canvas.Update(false);
   ChartRedraw();
}

#endif
