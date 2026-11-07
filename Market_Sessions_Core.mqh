#ifndef MARKET_SESSIONS_CORE_MQH
#define MARKET_SESSIONS_CORE_MQH

enum BrokerDSTRule
{
   BROKER_DST_NONE,
   BROKER_DST_EUROPE,
   BROKER_DST_US,
   BROKER_DST_AUSTRALIA,
   BROKER_DST_NZ
};

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

datetime SessionUTC(const datetime reference, const int session)
{
   datetime utc = reference - (session == 2 ? 0 : 2 * 3600);
   if(session == 2 && IsDST(utc, BROKER_DST_US, 0, 60))
      utc -= 3600;
   else if(session == 1 && IsDST(utc - 3600, BROKER_DST_EUROPE, 0, 60))
      utc -= 3600;
   return utc;
}

datetime OpeningRangeStart(const datetime session_open)
{
   int period = PeriodSeconds(PERIOD_M15);
   return ((session_open + period - 1) / period) * period;
}

datetime NextSessionUTC(const datetime reference_day, const datetime open_utc,
                        const int &opening_minutes[])
{
   datetime next = 0;
   for(int day = -1; day <= 3; day++)
   {
      for(int s = 0; s < ArraySize(opening_minutes); s++)
      {
         datetime candidate = SessionUTC(reference_day + day * 86400 +
                                          opening_minutes[s] * 60, s);
         if(candidate > open_utc && (next == 0 || candidate < next))
            next = candidate;
      }
   }
   return next;
}

bool LoadOpeningRange(const string symbol, const datetime session_open,
                      const datetime now, double &highest, double &lowest)
{
   datetime start = OpeningRangeStart(session_open);
   if(now < start + PeriodSeconds(PERIOD_M15))
      return false;
   MqlRates bar[];
   if(CopyRates(symbol, PERIOD_M15, start, 1, bar) != 1 ||
      bar[0].time != start || bar[0].high <= bar[0].low ||
      !SeriesInfoInteger(symbol, PERIOD_M15, SERIES_SYNCHRONIZED))
      return false;
   highest = bar[0].high;
   lowest = bar[0].low;
   return true;
}

// The input array is chronological, as returned by CopyRates without AS_SERIES.
int FindOpeningBreak(const MqlRates &rates[], const datetime range_close,
                     const datetime next_session, const datetime now,
                     const double high, const double low, datetime &confirmation)
{
   confirmation = 0;
   for(int i = 0; i < ArraySize(rates); i++)
   {
      datetime closed = rates[i].time + PeriodSeconds(PERIOD_M5);
      if(rates[i].time < range_close || closed > now || closed >= next_session)
         continue;
      int direction = rates[i].close > high ? 1 : (rates[i].close < low ? -1 : 0);
      if(direction != 0)
      {
         confirmation = rates[i].time;
         return direction;
      }
   }
   return 0;
}

double FloorVolume(const double volume, const double step)
{
   return NormalizeDouble(MathFloor(volume / step + 1e-8) * step, 8);
}

bool MidpointEntryEligible(const bool first_open, const bool profit_taken,
                           const bool second_entered, const bool buy,
                           const double entry, const double executable,
                           const double ask, const double bid, const double midpoint)
{
   return first_open && !profit_taken && !second_entered &&
          (buy ? executable < entry && ask <= midpoint :
                 executable > entry && bid >= midpoint);
}

double StopPrice(const double price, const double tick_size, const bool buy)
{
   return NormalizeDouble((buy ? MathFloor(price / tick_size + 1e-8) :
                                MathCeil(price / tick_size - 1e-8)) * tick_size, 8);
}

#endif
