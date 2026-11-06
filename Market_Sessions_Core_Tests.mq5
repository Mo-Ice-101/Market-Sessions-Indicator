#property strict
#property script_show_inputs

#include "Market_Sessions_Core.mqh"

int g_failures = 0;

void Check(const bool condition, const string name)
{
   if(!condition)
   {
      Print("FAIL: ", name);
      g_failures++;
   }
}

datetime FixedServer(const datetime reference, const int session, const int offset)
{
   return SessionUTC(reference, session) + offset * 60;
}

void OnStart()
{
   Check(FixedServer(D'2026.03.06 10:00', 1, 120) == D'2026.03.06 10:00',
         "Winter London on fixed UTC+2");
   Check(FixedServer(D'2026.03.30 10:00', 1, 120) == D'2026.03.30 09:00',
         "Summer London on fixed UTC+2");
   Check(FixedServer(D'2026.03.06 14:30', 2, 120) == D'2026.03.06 16:30',
         "Winter NY on fixed UTC+2");
   Check(FixedServer(D'2026.03.09 14:30', 2, 120) == D'2026.03.09 15:30',
         "US/Europe transition mismatch");
   Check(FixedServer(D'2026.10.26 10:00', 1, 120) == D'2026.10.26 10:00',
         "London after autumn transition");
   Check(FixedServer(D'2026.10.26 14:30', 2, 120) == D'2026.10.26 15:30',
         "NY before autumn transition");
   Check(FixedServer(D'2026.11.02 14:30', 2, 120) == D'2026.11.02 16:30',
         "NY after autumn transition");
   Check(FixedServer(D'2026.03.30 00:00', 0, 120) == D'2026.03.30 00:00',
         "Asian has no regional DST");
   Check(FixedServer(D'2026.03.30 14:30', 2, 345) == D'2026.03.30 19:15',
         "Fractional UTC+5:45 broker");
   Check(FixedServer(D'2026.03.30 00:00', 0, -300) == D'2026.03.29 17:00',
         "Reference crosses previous broker date");
   Check(IsDST(D'2026.03.08 07:00', BROKER_DST_US, 120, 60), "US DST start inclusive");
   Check(!IsDST(D'2026.03.08 06:59', BROKER_DST_US, 120, 60), "US before DST start");
   Check(!IsDST(D'2026.11.01 06:00', BROKER_DST_US, 120, 60), "US DST end exclusive");
   Check(IsDST(D'2026.01.01', BROKER_DST_AUSTRALIA, 600, 60), "Australian summer");
   Check(!IsDST(D'2026.07.01', BROKER_DST_AUSTRALIA, 600, 60), "Australian winter");
   Check(IsDST(D'2026.01.01', BROKER_DST_NZ, 720, 60), "NZ summer");

   Check(OpeningRangeStart(D'2026.11.02 08:00') == D'2026.11.02 08:00',
         "Aligned opening M15 candle");
   Check(OpeningRangeStart(D'2026.11.02 08:07') == D'2026.11.02 08:15',
         "Nonaligned session uses first full M15 candle");
   int openings[3] = {0, 600, 870};
   Check(NextSessionUTC(D'2026.11.02', D'2026.11.01 22:00', openings) ==
         D'2026.11.02 08:00', "Asian levels end at London UTC opening");
   Check(NextSessionUTC(D'2026.11.02', D'2026.11.02 14:30', openings) ==
         D'2026.11.02 22:00', "NY levels end at next Asian UTC opening");
   Check(NextSessionUTC(D'2026.03.09', D'2026.03.09 08:00', openings) ==
         D'2026.03.09 13:30', "Next session uses NY regional DST");
   int defaults[3] = {60, 660, 810};
   Check(FixedServer(D'2026.11.02 01:00', 0, 120) == D'2026.11.02 01:00',
         "Requested Asian opening default");
   Check(FixedServer(D'2026.11.02 11:00', 1, 120) == D'2026.11.02 11:00',
         "Requested London winter opening default");
   Check(FixedServer(D'2026.11.02 13:30', 2, 120) == D'2026.11.02 15:30',
         "Requested NY UTC winter reference default");
   Check(FixedServer(D'2026.03.30 11:00', 1, 120) == D'2026.03.30 10:00',
         "Requested London summer opening default");
   Check(FixedServer(D'2026.03.30 13:30', 2, 120) == D'2026.03.30 14:30',
         "Requested NY summer opening default");
   Check(NextSessionUTC(D'2026.11.02', D'2026.11.01 23:00', defaults) ==
         D'2026.11.02 09:00', "Requested defaults Asian-to-London boundary");
   Check(NextSessionUTC(D'2026.11.02', D'2026.11.02 13:30', defaults) ==
         D'2026.11.02 23:00', "Requested defaults NY-to-Asian boundary");

   MqlRates bars[4];
   ZeroMemory(bars);
   for(int i = 0; i < 4; i++)
   {
      bars[i].time = D'2026.11.02 08:15' + i * 300;
      bars[i].high = 120;
      bars[i].low = 80;
      bars[i].close = 100;
   }
   datetime confirmation;
   Check(FindOpeningBreak(bars, D'2026.11.02 08:15', D'2026.11.02 10:00', D'2026.11.02 09:00',
                          110, 90, confirmation) == 0, "Wicks do not signal");
   bars[0].close = 110;
   bars[1].close = 90;
   Check(FindOpeningBreak(bars, D'2026.11.02 08:15', D'2026.11.02 10:00', D'2026.11.02 09:00',
                          110, 90, confirmation) == 0, "Boundary equality does not signal");
   bars[2].close = 111;
   bars[3].close = 89;
   Check(FindOpeningBreak(bars, D'2026.11.02 08:15', D'2026.11.02 10:00', D'2026.11.02 09:00',
                          110, 90, confirmation) == 1 &&
         confirmation == D'2026.11.02 08:25', "First M5 breakout wins");
   Check(FindOpeningBreak(bars, D'2026.11.02 08:15', D'2026.11.02 10:00', D'2026.11.02 08:29',
                          110, 90, confirmation) == 0, "Forming candle ignored");
   Check(FindOpeningBreak(bars, D'2026.11.02 08:15', D'2026.11.02 08:30', D'2026.11.02 09:00',
                          110, 90, confirmation) == 0, "No breakout at/after next opening");
   bars[0].close = 111;
   bars[1].close = 89;
   bars[0].time = D'2026.11.02 08:10';
   bars[1].time = D'2026.11.02 08:15';
   Check(FindOpeningBreak(bars, D'2026.11.02 08:15', D'2026.11.02 10:00', D'2026.11.02 08:20',
                          110, 90, confirmation) == -1 &&
         confirmation == D'2026.11.02 08:15', "Opening-range candle cannot confirm itself");
   bars[0].time = D'2026.11.02 23:55';
   bars[1].time = D'2026.11.03 00:00';
   Check(FindOpeningBreak(bars, D'2026.11.03 00:00', D'2026.11.03 10:00', D'2026.11.03 00:05',
                          110, 90, confirmation) == -1 &&
         confirmation == D'2026.11.03 00:00', "Overnight session confirmation");

   Check(MathAbs(FloorVolume(0.119, 0.02) - 0.10) < 1e-8,
         "Risk volume rounds down to two steps");
   Check(MathAbs(FloorVolume(0.10, 0.02) - 0.10) < 1e-8,
         "Exact volume is not rounded down again");
   Check(MathAbs(FloorVolume(0.015, 0.01) - 0.01) < 1e-8,
         "Odd-step fixed lots cannot yield an exact half");
   Check(MathAbs(StopPrice(100.13, 0.25, true) - 100.00) < 1e-8,
         "Buy initial/trailing stop rounds down to tick");
   Check(MathAbs(StopPrice(100.13, 0.25, false) - 100.25) < 1e-8,
         "Sell initial/trailing stop rounds up to tick");
   Print(g_failures == 0 ? "PASS: all Market Sessions Core assertions." :
                         StringFormat("FAIL: %d assertions.", g_failures));
}
