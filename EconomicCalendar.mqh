#ifndef MARKET_SESSIONS_ECONOMIC_CALENDAR
#define MARKET_SESSIONS_ECONOMIC_CALENDAR

#define CALENDAR_MAX_EVENTS 512

struct EventInfo
{
   string name;
   string event_code; // Native identifier normalized for language-independent classification.
   string forecast;
   string actual;
   string previous;
   string unit;
   datetime release_time; // UTC, never broker/server time.
   int impact_level;      // 3 high, 2 medium, 1 low.
   int gold_impact_direction; // +1 bullish, -1 bearish, 0 neutral.
   bool hour_alerted;
   bool release_alerted;
};

string CalendarTrim(string text)
{
   StringTrimLeft(text);
   StringTrimRight(text);
   return text;
}

string CalendarLower(string text)
{
   StringToLower(text);
   return text;
}

bool CalendarContains(const string text,const string part)
{
   return StringFind(text,part)>=0;
}

bool CalendarDigit(const ushort c) { return c>='0' && c<='9'; }

bool CalendarMissing(const string text)
{
   string value=CalendarLower(CalendarTrim(text));
   return value=="" || value=="null" || value=="n/a" || value=="na" ||
          value=="--" || value=="-" || value=="none" || value=="not available" ||
          value=="pending" || value=="tba" || value=="nan";
}

// Commas mean validated thousands groups; decimal commas are ambiguous and rejected.
// Deliberately excludes ranges, exponents, missing values and loose numeric prefixes.
bool CalendarNumber(const string text,double &value)
{
   string s=CalendarTrim(text);
   int n=StringLen(s);
   if(n==0) return false;
   double scale=1.0;
   ushort suffix=StringGetCharacter(s,n-1);
   if(suffix=='%' || suffix=='K' || suffix=='k' || suffix=='M' ||
      suffix=='m' || suffix=='B' || suffix=='b')
   {
      if(suffix=='K' || suffix=='k') scale=1000.0;
      if(suffix=='M' || suffix=='m') scale=1000000.0;
      if(suffix=='B' || suffix=='b') scale=1000000000.0;
      s=CalendarTrim(StringSubstr(s,0,n-1));
      n=StringLen(s);
   }
   int i=0;
   if(n>0 && (StringGetCharacter(s,0)=='+' || StringGetCharacter(s,0)=='-')) i++;
   int digits=0,group=0;
   bool comma=false;
   string clean=StringSubstr(s,0,i);
   for(;i<n;i++)
   {
      ushort c=StringGetCharacter(s,i);
      if(CalendarDigit(c)) { digits++; group++; clean+=ShortToString(c); }
      else if(c==',')
      {
         if(group==0 || (!comma && group>3) || (comma && group!=3)) return false;
         comma=true;
         group=0;
      }
      else break;
   }
   if(comma && group!=3) return false;
   if(i<n && StringGetCharacter(s,i)=='.')
   {
      clean+=".";
      i++;
      int fraction=0;
      for(;i<n && CalendarDigit(StringGetCharacter(s,i));i++)
      {
         clean+=ShortToString(StringGetCharacter(s,i));
         digits++;
         fraction++;
      }
      if(fraction==0) return false;
   }
   if(digits==0 || i!=n) return false;
   double parsed=StringToDouble(clean)*scale;
   if(!MathIsValidNumber(parsed)) return false;
   value=parsed;
   return true;
}

int CalendarGoldDirection(const EventInfo &event)
{
   if(event.release_time>TimeGMT()) return 0;
   string name=CalendarLower(event.name+" "+event.event_code);
   string actual=CalendarLower(CalendarTrim(event.actual));
   if(CalendarMissing(actual) || CalendarContains(name,"ecb") || CalendarContains(name,"auction"))
      return 0;
   if(CalendarContains(name,"recession"))
      return actual=="yes" || actual=="true" || actual=="recession" ? 1 : 0;
   bool rate=CalendarContains(name,"rate decision") ||
             CalendarContains(name,"interest rate") ||
             CalendarContains(name,"federal funds") ||
             CalendarContains(name,"cash rate");
   bool fed=CalendarContains(name,"fed") || CalendarContains(name,"fomc");
   if(fed && (CalendarContains(actual,"hike") || CalendarContains(actual,"cut")))
   {
      bool hike=CalendarContains(actual,"hike"),cut=CalendarContains(actual,"cut");
      return hike==cut ? 0 : (hike ? -1 : 1);
   }
   double a=0,f=0;
   if(!CalendarNumber(event.actual,a)) return 0;
   // Negative GDP growth is a safe-haven signal, not a forecast-surprise comparison.
   if((CalendarContains(name,"gdp") || CalendarContains(name,"gross domestic")) &&
      !CalendarContains(name,"price") &&
      !CalendarContains(name,"deflator") && a<0.0) return 1;
   if(rate)
   {
      if(!CalendarNumber(event.previous,f) || a==f) return 0;
      return a>f ? -1 : 1;
   }
   if(CalendarContains(name,"china") && CalendarContains(name,"pmi") && a<50.0)
      return 1;
   if(!CalendarNumber(event.forecast,f) || a==f) return 0;
   bool inverse=CalendarContains(name,"unemployment") || CalendarContains(name,"jobless");
   bool normal=CalendarContains(name,"cpi") || CalendarContains(name,"consumer price") ||
      CalendarContains(name,"inflation") || CalendarContains(name,"pce") ||
      CalendarContains(name,"personal consumption") || CalendarContains(name,"ppi") ||
      CalendarContains(name,"producer price") || CalendarContains(name,"nfp") ||
      CalendarContains(name,"non-farm") || CalendarContains(name,"nonfarm") ||
      CalendarContains(name,"payroll") || CalendarContains(name,"retail") ||
      CalendarContains(name,"gdp") || CalendarContains(name,"gross domestic") ||
      CalendarContains(name,"pmi");
   if(!inverse && !normal) return 0;
   return (a>f ? -1 : 1)*(inverse ? -1 : 1);
}

bool CalendarRelevant(const string currency,const string title)
{
   string name=CalendarLower(title),c=CalendarLower(currency);
   if(c!="usd" && c!="us" && c!="united states") return false;
   return CalendarContains(name,"cpi") || CalendarContains(name,"consumer price") ||
      CalendarContains(name,"inflation") || CalendarContains(name,"pce") ||
      CalendarContains(name,"personal consumption") || CalendarContains(name,"nfp") ||
      CalendarContains(name,"non-farm") || CalendarContains(name,"nonfarm") ||
      CalendarContains(name,"payroll") || CalendarContains(name,"fed") ||
      CalendarContains(name,"fomc") || CalendarContains(name,"interest rate") ||
      CalendarContains(name,"unemployment") || CalendarContains(name,"retail") ||
      CalendarContains(name,"ppi") || CalendarContains(name,"producer price") ||
      CalendarContains(name,"auction") || CalendarContains(name,"treasury") ||
      CalendarContains(name,"jobless") ||
      CalendarContains(name,"gdp") || CalendarContains(name,"gross domestic") ||
      CalendarContains(name,"recession");
}

void CalendarSort(EventInfo &events[])
{
   for(int i=1;i<ArraySize(events);i++)
   {
      EventInfo item=events[i];
      int j=i-1;
      while(j>=0 && events[j].release_time>item.release_time)
      {
         events[j+1]=events[j];
         j--;
      }
      events[j+1]=item;
   }
}

bool CalendarCopy(EventInfo &destination[],const EventInfo &source[])
{
   int count=ArraySize(source);
   if(ArrayResize(destination,count)<0) return false;
   for(int i=0;i<count;i++) destination[i]=source[i];
   return true;
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

bool ReadNativeCalendar(EventInfo &events[],datetime &last_success,bool &available)
{
   available=false;
   datetime utc_now=TimeGMT(),server_now=TimeTradeServer();
   if(server_now<=0) return false;
   // Calendar queries use server time; the existing overlay expects UTC.
   long offset=(long)MathRound((double)(server_now-utc_now)/60.0)*60;
   if(offset<-14*3600 || offset>14*3600) return false;
   datetime today_start=utc_now-utc_now%86400;
   datetime today_end=today_start+86400;
   MqlCalendarValue values[];
   ResetLastError();
   int count=CalendarValueHistory(values,(datetime)(today_start+offset),
                                  (datetime)(today_end+offset),NULL,"USD");
   if(count<0) return false;
   EventInfo fetched[];
   for(int i=0;i<count;i++)
   {
      datetime release_time=(datetime)((long)values[i].time-offset);
      if(release_time<today_start || release_time>=today_end) continue;
      MqlCalendarEvent report;
      if(!CalendarEventById(values[i].event_id,report)) return false;
      string code=report.event_code;
      StringReplace(code,"-"," ");
      StringReplace(code,"_"," ");
      if(!CalendarRelevant("USD",report.name+" "+code) || values[i].time<=0 ||
         report.importance<CALENDAR_IMPORTANCE_LOW ||
         report.importance>CALENDAR_IMPORTANCE_HIGH ||
         report.time_mode!=CALENDAR_TIMEMODE_DATETIME) continue;
      EventInfo event;
      event.name=report.name;
      event.event_code=code;
      event.release_time=release_time;
      event.impact_level=(int)report.importance;
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
   CalendarSort(fetched);
   if(!CalendarCopy(events,fetched)) return false;
   last_success=utc_now;
   available=true;
   return true;
}

#endif
