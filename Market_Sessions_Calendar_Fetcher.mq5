#property strict
#property version "1.10"
#property description "Optional non-trading MT5-native calendar monitor. The indicator reads MT5 directly."

#include "EconomicCalendar.mqh"

void CalendarPoll()
{
   EventInfo events[];
   datetime success=0;
   bool available=false;
   if(ReadNativeCalendar(events,success,available))
      PrintFormat("MT5 calendar loaded: %d relevant USD events (next 14 days and last 24 hours).",
                  ArraySize(events));
   else
      PrintFormat("MT5 calendar unavailable (terminal error %d). Check the MT5 Calendar tab.",
                  GetLastError());
}

int OnInit()
{
   if(!EventSetTimer(60)) return INIT_FAILED;
   Print("Using only MT5's native calendar. No API keys or WebRequest permissions. This EA never trades; attach Market Sessions Boxes for chart labels.");
   CalendarPoll();
   return INIT_SUCCEEDED;
}

void OnTimer() { CalendarPoll(); }

void OnDeinit(const int reason)
{
   EventKillTimer();
}
