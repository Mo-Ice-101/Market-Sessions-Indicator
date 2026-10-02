#property strict
#property version "1.00"
#property description "Non-trading calendar cache writer. Attach ONE instance per terminal."

#include "EconomicCalendar.mqh"

input int CalendarPollMinutes=30; // Allowed: 30-60 minutes; timer checks every 60 seconds.
input bool UseMT5Calendar=true; // No key: try built-in MT5 actuals first; public schedule fallback.
input string Fin2DevAPIKey=""; // Optional; access/limits depend on the provider's current plan.
input int Fin2DevUtcOffsetMinutes=0; // Undocumented datetime timezone: assume UTC unless configured.
input bool Fin2DevImpactOneIsHigh=true; // Provisional mapping (undocumented): 1 high; false = 3 high.
input int RequestTimeoutMilliseconds=10000;

EventInfo g_calendar[];
datetime g_success=0,g_attempt=0;
bool g_available=false;
int g_writer_lock=INVALID_HANDLE;

int CalendarPreferredSource()
{
   return Fin2DevAPIKey!="" ? 2 : UseMT5Calendar ? 3 : 1;
}

string CalendarNativeNumber(const long raw)
{
   if(raw==LONG_MIN) return "";
   string number=DoubleToString((double)raw/1000000.0,6);
   while(StringLen(number)>0 && StringSubstr(number,StringLen(number)-1,1)=="0")
      number=StringSubstr(number,0,StringLen(number)-1);
   if(StringLen(number)>0 && StringSubstr(number,StringLen(number)-1,1)==".")
      number=StringSubstr(number,0,StringLen(number)-1);
   return number;
}

string CalendarNativeUnit(const MqlCalendarEvent &report)
{
   if(report.unit==CALENDAR_UNIT_PERCENT) return "percent";
   switch(report.multiplier)
   {
      case CALENDAR_MULTIPLIER_THOUSANDS: return "K";
      case CALENDAR_MULTIPLIER_MILLIONS: return "M";
      case CALENDAR_MULTIPLIER_BILLIONS: return "B";
      case CALENDAR_MULTIPLIER_TRILLIONS: return "T";
      case CALENDAR_MULTIPLIER_NONE: return "";
   }
   return "";
}

bool CalendarNative(EventInfo &events[],const datetime utc_now)
{
   datetime server_now=TimeTradeServer();
   if(server_now<=0) return false;
   // TimeGMT requires a correct computer clock. Use the current broker offset,
   // rounded to a minute, throughout this window (including across a DST boundary).
   long offset=(long)MathRound((double)(server_now-utc_now)/60.0)*60;
   if(offset<-14*3600 || offset>14*3600) return false;
   string currencies[3]={"USD","EUR","CNY"};
   EventInfo fetched[];
   for(int c=0;c<3;c++)
   {
      MqlCalendarValue values[];
      ResetLastError();
      int count=CalendarValueHistory(values,server_now-86400,server_now+7*86400,
                                    NULL,currencies[c]);
      if(count<0 || count>32768) return false;
      for(int i=0;i<count;i++)
      {
         MqlCalendarEvent report;
         if(!CalendarEventById(values[i].event_id,report)) return false;
         if(!CalendarRelevant(currencies[c],report.name) || values[i].time<=0 ||
            report.importance<CALENDAR_IMPORTANCE_LOW ||
            report.importance>CALENDAR_IMPORTANCE_HIGH) continue;
         if(EnumToString(report.time_mode)!="CALENDAR_TIMEMODE_DATETIME") continue;
         EventInfo event;
         event.name=report.name;
         string lower=CalendarLower(event.name);
         if(c==1 && !CalendarContains(lower,"ecb")) event.name="ECB: "+event.name;
         if(c==2 && !CalendarContains(lower,"china")) event.name="China: "+event.name;
         event.release_time=(datetime)((long)values[i].time-offset);
         event.impact_level=(int)report.importance;
         // Bare values share one native scale; the unit metadata supplies display suffixes.
         event.actual=CalendarNativeNumber(values[i].actual_value);
         event.forecast=CalendarNativeNumber(values[i].forecast_value);
         event.previous=CalendarNativeNumber(values[i].prev_value);
         event.unit=CalendarNativeUnit(report);
         event.gold_impact_direction=CalendarGoldDirection(event);
         event.hour_alerted=false;
         event.release_alerted=false;
         int used=ArraySize(fetched);
         if(used>=CALENDAR_MAX_EVENTS || ArrayResize(fetched,used+1)<0) return false;
         fetched[used]=event;
      }
   }
   EventInfo none[];
   return CalendarRefresh(events,none,fetched,utc_now,false);
}

string CalendarURLKey(const string key)
{
   uchar bytes[];
   int size=StringToCharArray(key,bytes,0,WHOLE_ARRAY,CP_UTF8)-1;
   string encoded="";
   for(int i=0;i<size;i++)
   {
      int c=bytes[i];
      if((c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') ||
         c=='-' || c=='_' || c=='.' || c=='~') encoded+=ShortToString((ushort)c);
      else encoded+=StringFormat("%%%02X",c);
   }
   return encoded;
}

bool CalendarDownload(const string url,const bool fin2dev,EventInfo &events[])
{
   char request[],response[];
   string headers;
   ResetLastError();
   int status=WebRequest("GET",url,"Accept: application/json\r\n",
                         RequestTimeoutMilliseconds,request,response,headers);
   // Never print URLs, response bodies or headers: these may contain a provider key.
   if(status!=200)
   {
      PrintFormat("Calendar request failed (HTTP %d, terminal error %d). Check WebRequest allowlist/network/provider access.",
                  status,GetLastError());
      return false;
   }
   if(ArraySize(response)==0 || ArraySize(response)>CALENDAR_MAX_BYTES) return false;
   string payload=CharArrayToString(response,0,ArraySize(response),CP_UTF8);
   if(!ParseCalendarJSON(payload,fin2dev,fin2dev ? Fin2DevUtcOffsetMinutes : 0,
                         events,Fin2DevImpactOneIsHigh))
   {
      Print("Calendar payload rejected; keeping last-known events.");
      return false;
   }
   return true;
}

void CalendarPoll()
{
   datetime now=TimeGMT();
   if(g_attempt>0 && now>=g_attempt && now-g_attempt<CalendarPollMinutes*60) return;
   g_attempt=now;
   EventInfo fetched[],candidate[];
   int provider=CalendarPreferredSource();
   bool ok=true;
   if(Fin2DevAPIKey=="")
   {
      ok=UseMT5Calendar && CalendarNative(fetched,now);
      if(!ok)
      {
         // A native outage must not replace known published actuals with a schedule.
         if(UseMT5Calendar && CalendarCacheSource==3 && g_success>0)
            Print("MT5 calendar unavailable; retaining last-known native actuals.");
         else
         {
            if(UseMT5Calendar)
               Print("MT5 calendar unavailable; trying public schedule-only fallback.");
            provider=1;
            ok=CalendarDownload("https://nfs.faireconomy.media/ff_calendar_thisweek.json",false,fetched);
         }
      }
   }
   else
   {
      // Euro_Area is a provider country label, not an invented ISO country code.
      string regions[3]={"&iso_country_code=us","&country=Euro_Area","&iso_country_code=cn"};
      string base="https://apidata.fin2dev.com/v1/macrocalendar?key="+CalendarURLKey(Fin2DevAPIKey);
      // Use the provider's default window; date-range filters may require a higher plan.
      for(int i=0;i<3 && ok;i++)
      {
         EventInfo region[];
         ok=CalendarDownload(base+regions[i],true,region);
         if(ok) ok=CalendarMerge(fetched,region,now);
      }
   }
   if(ok)
   {
      ok=CalendarRefresh(candidate,g_calendar,fetched,now,CalendarCacheSource==provider);
   }
   if(ok)
   {
      // Publish first; do not announce success for a failed disk write.
      int old_source=CalendarCacheSource;
      CalendarCacheSource=provider;
      if(WriteCalendarCache(candidate,now,g_attempt,true))
      {
         g_success=now;
         g_available=true;
         if(!CalendarCopy(g_calendar,candidate))
         {
            // The published cache is intact; stop rather than overwrite it from stale memory.
            Print("Calendar memory allocation failed; removing fetcher. The published cache remains intact.");
            ExpertRemove();
            return;
         }
         PrintFormat("Calendar cache updated: %d relevant events.",ArraySize(g_calendar));
         return;
      }
      CalendarCacheSource=old_source;
      Print("Calendar cache update failed; keeping last-known events.");
   }
   g_available=false;
   EventInfo none[];
   CalendarMerge(g_calendar,none,now);
   if(!WriteCalendarCache(g_calendar,g_success,g_attempt,false))
      Print("Could not publish calendar failure status.");
}

int OnInit()
{
   if(CalendarPollMinutes<30 || CalendarPollMinutes>60 || Fin2DevUtcOffsetMinutes<-840 ||
      Fin2DevUtcOffsetMinutes>840 || RequestTimeoutMilliseconds<1000 ||
      RequestTimeoutMilliseconds>30000) return INIT_PARAMETERS_INCORRECT;
   // FILE_COMMON also serializes writers in other terminals sharing the common folder.
   // Keep the handle open, without sharing flags, for the entire EA lifetime.
   g_writer_lock=FileOpen(ECONOMIC_CACHE_FILE+".lock",FILE_READ|FILE_WRITE|FILE_BIN|FILE_COMMON);
   if(g_writer_lock==INVALID_HANDLE)
   {
      Print("Calendar writer already active or common folder unavailable. Use ONE fetcher instance.");
      return INIT_FAILED;
   }
   ReadCalendarCache(g_calendar,g_success,g_attempt,g_available);
   if(CalendarCacheSource!=CalendarPreferredSource()) g_attempt=0;
   if(!EventSetTimer(60))
   {
      FileClose(g_writer_lock);
      g_writer_lock=INVALID_HANDLE;
      return INIT_FAILED;
   }
   Print("Allow WebRequest for https://nfs.faireconomy.media and, if using a key, https://apidata.fin2dev.com. This EA never trades.");
   CalendarPoll();
   return INIT_SUCCEEDED;
}

void OnTimer() { CalendarPoll(); }

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_writer_lock!=INVALID_HANDLE) FileClose(g_writer_lock);
   g_writer_lock=INVALID_HANDLE;
}
