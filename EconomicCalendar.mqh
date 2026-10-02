#ifndef MARKET_SESSIONS_ECONOMIC_CALENDAR
#define MARKET_SESSIONS_ECONOMIC_CALENDAR

#define ECONOMIC_CACHE_FILE "MarketSessionsCalendar.bin"
#define CALENDAR_MAX_EVENTS 512
#define CALENDAR_MAX_TEXT 4096
#define CALENDAR_MAX_BYTES 2097152

// Cache provenance only: 0 unknown, 1 public schedule, 2 Fin2Dev, 3 MT5. Never a key.
int CalendarCacheSource=0;

struct EventInfo
{
   string name;
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
   string name=CalendarLower(event.name);
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

struct CalendarJSONNode
{
   int kind; // 1 object, 2 array, 3 string, 4 number, 5 bool, 6 null.
   int next;
   string text;
};

// A bounded, full-document parser; an invalid tail cannot replace the cache.
class CCalendarJSON
{
private:
   string m_source;
   int m_pos,m_used;
   CalendarJSONNode m_nodes[];
   void Space()
   {
      while(m_pos<StringLen(m_source))
      {
         ushort c=StringGetCharacter(m_source,m_pos);
         if(c!=' ' && c!='\t' && c!='\r' && c!='\n') break;
         m_pos++;
      }
   }
   int Hex(const ushort c)
   {
      if(c>='0' && c<='9') return c-'0';
      if(c>='a' && c<='f') return c-'a'+10;
      if(c>='A' && c<='F') return c-'A'+10;
      return -1;
   }
   bool Unicode(ushort &code)
   {
      int v=0;
      for(int i=0;i<4;i++)
      {
         if(m_pos>=StringLen(m_source)) return false;
         int h=Hex(StringGetCharacter(m_source,m_pos++));
         if(h<0) return false;
         v=v*16+h;
      }
      code=(ushort)v;
      return true;
   }
   bool StringValue(string &out)
   {
      if(m_pos>=StringLen(m_source) || StringGetCharacter(m_source,m_pos++)!='"')
         return false;
      out="";
      while(m_pos<StringLen(m_source))
      {
         ushort c=StringGetCharacter(m_source,m_pos++);
         if(c=='"') return true;
         if(c<32) return false;
         if(c=='\\')
         {
            if(m_pos>=StringLen(m_source)) return false;
            c=StringGetCharacter(m_source,m_pos++);
            if(c=='u')
            {
               if(!Unicode(c) || (c>=0xDC00 && c<=0xDFFF)) return false;
               if(c>=0xD800 && c<=0xDBFF)
               {
                  if(c==0) return false;
                  out+=ShortToString(c);
                  if(StringSubstr(m_source,m_pos,2)!="\\u") return false;
                  m_pos+=2;
                  if(!Unicode(c) || c<0xDC00 || c>0xDFFF) return false;
               }
            }
            else if(c=='n') c='\n';
            else if(c=='r') c='\r';
            else if(c=='t') c='\t';
            else if(c=='b') c=8;
            else if(c=='f') c=12;
            else if(c!='"' && c!='\\' && c!='/') return false;
         }
         out+=ShortToString(c);
         if(StringLen(out)>CALENDAR_MAX_TEXT) return false;
      }
      return false;
   }
   int NewNode(const int kind)
   {
      if(m_used>=32768) return -1;
      if(m_used>=ArraySize(m_nodes) && ArrayResize(m_nodes,m_used+512)<0) return -1;
      int at=m_used++;
      m_nodes[at].kind=kind;
      m_nodes[at].text="";
      m_nodes[at].next=at+1;
      return at;
   }
   bool Value(const int depth)
   {
      if(depth>32) return false;
      Space();
      if(m_pos>=StringLen(m_source)) return false;
      ushort c=StringGetCharacter(m_source,m_pos);
      int at=NewNode(c=='{' ? 1 : c=='[' ? 2 : c=='"' ? 3 : 4);
      if(at<0) return false;
      if(c=='{' || c=='[')
      {
         bool object=(c=='{');
         ushort end=object ? '}' : ']';
         m_pos++;
         Space();
         if(m_pos<StringLen(m_source) && StringGetCharacter(m_source,m_pos)==end)
            m_pos++;
         else
         {
            while(true)
            {
               if(object)
               {
                  Space();
                  int key=NewNode(3);
                  if(key<0 || !StringValue(m_nodes[key].text)) return false;
                  Space();
                  if(m_pos>=StringLen(m_source) || StringGetCharacter(m_source,m_pos++)!=':')
                     return false;
               }
               if(!Value(depth+1)) return false;
               Space();
               if(m_pos>=StringLen(m_source)) return false;
               c=StringGetCharacter(m_source,m_pos++);
               if(c==end) break;
               if(c!=',') return false;
            }
         }
      }
      else if(c=='"')
      {
         if(!StringValue(m_nodes[at].text)) return false;
      }
      else if(c=='t' || c=='f' || c=='n')
      {
         string literal=c=='t' ? "true" : c=='f' ? "false" : "null";
         if(StringSubstr(m_source,m_pos,StringLen(literal))!=literal) return false;
         m_pos+=StringLen(literal);
         m_nodes[at].kind=c=='n' ? 6 : 5;
         m_nodes[at].text=literal;
      }
      else
      {
         int start=m_pos,n=StringLen(m_source);
         if(c=='-') m_pos++;
         if(m_pos>=n || !CalendarDigit(StringGetCharacter(m_source,m_pos))) return false;
         if(StringGetCharacter(m_source,m_pos)=='0') m_pos++;
         else while(m_pos<n && CalendarDigit(StringGetCharacter(m_source,m_pos))) m_pos++;
         if(m_pos<n && StringGetCharacter(m_source,m_pos)=='.')
         {
            m_pos++;
            int first=m_pos;
            while(m_pos<n && CalendarDigit(StringGetCharacter(m_source,m_pos))) m_pos++;
            if(first==m_pos) return false;
         }
         if(m_pos<n && (StringGetCharacter(m_source,m_pos)=='e' ||
                        StringGetCharacter(m_source,m_pos)=='E'))
         {
            m_pos++;
            if(m_pos<n && (StringGetCharacter(m_source,m_pos)=='+' ||
                           StringGetCharacter(m_source,m_pos)=='-')) m_pos++;
            int first=m_pos;
            while(m_pos<n && CalendarDigit(StringGetCharacter(m_source,m_pos))) m_pos++;
            if(first==m_pos) return false;
         }
         m_nodes[at].text=StringSubstr(m_source,start,m_pos-start);
      }
      m_nodes[at].next=m_used;
      return true;
   }
public:
   bool Parse(const string source)
   {
      m_source=source;
      m_pos=0;
      m_used=0;
      if(StringLen(source)==0 || StringLen(source)>CALENDAR_MAX_BYTES || !Value(0))
         return false;
      Space();
      return m_pos==StringLen(m_source);
   }
   int Kind(const int at) { return at>=0 && at<m_used ? m_nodes[at].kind : 0; }
   int Next(const int at) { return at>=0 && at<m_used ? m_nodes[at].next : m_used; }
   string Text(const int at)
   {
      if(at<0 || at>=m_used || (m_nodes[at].kind!=3 && m_nodes[at].kind!=4 &&
                               m_nodes[at].kind!=5)) return "";
      return m_nodes[at].text;
   }
   int Find(const int at,const string key)
   {
      if(Kind(at)!=1) return -1;
      for(int i=at+1;i<Next(at);)
      {
         int value=i+1;
         if(m_nodes[i].text==key) return value;
         i=Next(value);
      }
      return -1;
   }
};

bool CalendarDate(const string text,const int assumed_offset,datetime &utc)
{
   int n=StringLen(text);
   if(n<16 || StringSubstr(text,4,1)!="-" || StringSubstr(text,7,1)!="-" ||
      (StringSubstr(text,10,1)!="T" && StringSubstr(text,10,1)!=" ") ||
      StringSubstr(text,13,1)!=":") return false;
   int positions[5]={0,5,8,11,14},widths[5]={4,2,2,2,2},parts[5];
   for(int j=0;j<5;j++)
   {
      string part=StringSubstr(text,positions[j],widths[j]);
      for(int k=0;k<widths[j];k++) if(!CalendarDigit(StringGetCharacter(part,k))) return false;
      parts[j]=(int)StringToInteger(part);
   }
   int pos=16,sec=0,offset=assumed_offset;
   if(pos<n && StringSubstr(text,pos,1)==":")
   {
      if(n<pos+3 || !CalendarDigit(StringGetCharacter(text,pos+1)) ||
         !CalendarDigit(StringGetCharacter(text,pos+2))) return false;
      sec=(int)StringToInteger(StringSubstr(text,pos+1,2));
      pos+=3;
   }
   if(pos<n && StringSubstr(text,pos,1)==".")
   {
      int start=++pos;
      while(pos<n && CalendarDigit(StringGetCharacter(text,pos))) pos++;
      if(pos==start) return false;
   }
   if(pos<n && StringSubstr(text,pos,1)=="Z") { offset=0; pos++; }
   else if(pos<n && (StringSubstr(text,pos,1)=="+" || StringSubstr(text,pos,1)=="-"))
   {
      int sign=StringSubstr(text,pos,1)=="+" ? 1 : -1;
      if(n-pos!=6 || StringSubstr(text,pos+3,1)!=":") return false;
      for(int j=1;j<6;j++)
         if(j!=3 && !CalendarDigit(StringGetCharacter(text,pos+j))) return false;
      int h=(int)StringToInteger(StringSubstr(text,pos+1,2));
      int m=(int)StringToInteger(StringSubstr(text,pos+4,2));
      if(h>14 || m>59 || (h==14 && m!=0)) return false;
      offset=sign*(h*60+m);
      pos=n;
   }
   if(pos!=n || parts[0]<1970 || parts[0]>2100 || parts[1]<1 || parts[1]>12 ||
      parts[2]<1 || parts[2]>31 || parts[3]>23 || parts[4]>59 || sec>59) return false;
   MqlDateTime dt={0};
   dt.year=parts[0]; dt.mon=parts[1]; dt.day=parts[2];
   dt.hour=parts[3]; dt.min=parts[4]; dt.sec=sec;
   datetime raw=StructToTime(dt);
   MqlDateTime check={0};
   if(!TimeToStruct(raw,check) || check.year!=dt.year || check.mon!=dt.mon ||
      check.day!=dt.day || check.hour!=dt.hour || check.min!=dt.min) return false;
   utc=raw-offset*60;
   return utc>0;
}

bool CalendarRelevant(const string currency,const string title)
{
   string name=CalendarLower(title),c=CalendarLower(currency);
   if(c=="eur" || c=="ea" || c=="euro_area" || c=="euro area")
      return CalendarContains(name,"ecb") || CalendarContains(name,"interest rate decision") ||
         CalendarContains(name,"main refinancing") || CalendarContains(name,"deposit facility") ||
         CalendarContains(name,"marginal lending") || CalendarContains(name,"minimum bid rate");
   if(c=="cny" || c=="cn" || c=="china") return CalendarContains(name,"pmi");
   if(c!="usd" && c!="us" && c!="united states") return false;
   return CalendarContains(name,"cpi") || CalendarContains(name,"consumer price") ||
      CalendarContains(name,"inflation") || CalendarContains(name,"pce") ||
      CalendarContains(name,"personal consumption") || CalendarContains(name,"nfp") ||
      CalendarContains(name,"non-farm") || CalendarContains(name,"nonfarm") ||
      CalendarContains(name,"payroll") || CalendarContains(name,"fed") ||
      CalendarContains(name,"fomc") || CalendarContains(name,"rate") ||
      CalendarContains(name,"unemployment") || CalendarContains(name,"retail") ||
      CalendarContains(name,"ppi") || CalendarContains(name,"producer price") ||
      CalendarContains(name,"auction") || CalendarContains(name,"jobless") ||
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

// Retain published actuals when a subsequent schedule-only response omits them.
bool CalendarMerge(EventInfo &events[],const EventInfo &incoming[],const datetime now)
{
   int kept=0;
   for(int i=0;i<ArraySize(events);i++)
      if(events[i].release_time>=now-86400) events[kept++]=events[i];
   ArrayResize(events,kept);
   for(int i=0;i<ArraySize(incoming);i++)
   {
      if(incoming[i].release_time<now-86400) continue;
      int found=-1;
      for(int j=0;j<ArraySize(events);j++)
         if(events[j].name==incoming[i].name &&
            events[j].release_time==incoming[i].release_time) { found=j; break; }
      if(found<0)
      {
         if(ArraySize(events)>=CALENDAR_MAX_EVENTS) return false;
         found=ArraySize(events);
         if(ArrayResize(events,found+1)<0) return false;
         events[found]=incoming[i];
      }
      else
      {
         EventInfo replacement=incoming[i];
         if(CalendarMissing(replacement.actual)) replacement.actual=events[found].actual;
         if(replacement.forecast=="") replacement.forecast=events[found].forecast;
         if(replacement.previous=="") replacement.previous=events[found].previous;
         if(replacement.unit=="") replacement.unit=events[found].unit;
         replacement.hour_alerted=events[found].hour_alerted;
         replacement.release_alerted=events[found].release_alerted;
         events[found]=replacement;
      }
      events[found].gold_impact_direction=CalendarGoldDirection(events[found]);
   }
   int used=0;
   for(int i=0;i<ArraySize(events);i++)
      if(events[i].release_time>=now-86400) events[used++]=events[i];
   ArrayResize(events,used);
   CalendarSort(events);
   return true;
}

// A response is authoritative for future reports (including cancellations).
// Keep the last 24 hours of releases and actuals from the same provider.
bool CalendarRefresh(EventInfo &result[],const EventInfo &previous[],
                     const EventInfo &incoming[],const datetime now,
                     const bool same_provider)
{
   if(ArrayResize(result,0)<0) return false;
   if(same_provider)
   {
      for(int i=0;i<ArraySize(previous);i++)
      {
         if(previous[i].release_time<now-86400) continue;
         bool keep=previous[i].release_time<=now;
         for(int j=0;!keep && j<ArraySize(incoming);j++)
         {
            if(previous[i].name!=incoming[j].name ||
               previous[i].release_time!=incoming[j].release_time) continue;
            keep=true;
         }
         if(!keep) continue;
         int count=ArraySize(result);
         if(count>=CALENDAR_MAX_EVENTS || ArrayResize(result,count+1)<0) return false;
         result[count]=previous[i];
      }
   }
   return CalendarMerge(result,incoming,now);
}

bool ParseCalendarJSON(const string payload,const bool fin2dev,
                       const int utc_offset,EventInfo &events[],
                       const bool impact_one_high=true)
{
   CCalendarJSON json;
   if(!json.Parse(payload)) return false;
   int root=0;
   if(fin2dev)
   {
      root=json.Find(json.Find(0,"result"),"output");
      if(json.Kind(root)!=2 && json.Kind(root)!=1) return false;
   }
   else if(json.Kind(root)!=2) return false;
   EventInfo parsed[];
   // Fin2Dev may return an array or an object keyed by report identifiers.
   for(int i=root+1;i<json.Next(root);)
   {
      int row=i;
      if(json.Kind(root)==1) row=i+1;
      i=json.Next(row);
      if(json.Kind(row)!=1) return false;
      string name=json.Text(json.Find(row,fin2dev ? "report_name" : "title"));
      string country=json.Text(json.Find(row,fin2dev ? "iso_country_code" : "country"));
      string date=json.Text(json.Find(row,fin2dev ? "datetime" : "date"));
      if(fin2dev && !CalendarRelevant(country,name))
      {
         string fallback=json.Text(json.Find(row,"country"));
         if(fallback!="") country=fallback;
      }
      if(name=="" || country=="") return false;
      if(!CalendarRelevant(country,name)) continue;
      string timing=CalendarLower(CalendarTrim(json.Text(json.Find(row,"time"))));
      if(!fin2dev && (timing=="tentative" || timing=="all day" || timing=="all-day"))
         continue;
      EventInfo event;
      event.name=name;
      string c=CalendarLower(country);
      if((c=="eur" || c=="ea" || c=="euro_area" || c=="euro area") &&
         !CalendarContains(CalendarLower(name),"ecb")) event.name="ECB: "+name;
      if((c=="cn" || c=="cny" || c=="china") &&
         !CalendarContains(CalendarLower(name),"china")) event.name="China: "+name;
      if(!CalendarDate(date,utc_offset,event.release_time))
      {
         // Untimed public-feed announcements cannot drive countdowns or alerts.
         if(!fin2dev) continue;
         return false;
      }
      string impact=CalendarLower(json.Text(json.Find(row,"impact")));
      if(fin2dev)
      {
         if(impact!="1" && impact!="2" && impact!="3") return false;
         int level=(int)StringToInteger(impact);
         event.impact_level=impact_one_high ? 4-level : level;
      }
      else
      {
         if(impact!="high" && impact!="medium" && impact!="low") continue;
         event.impact_level=impact=="high" ? 3 : impact=="medium" ? 2 : 1;
      }
      event.forecast=json.Text(json.Find(row,fin2dev ? "consensus" : "forecast"));
      event.actual=CalendarTrim(json.Text(json.Find(row,"actual")));
      if(CalendarMissing(event.actual)) event.actual="";
      event.previous=json.Text(json.Find(row,"previous"));
      event.unit=json.Text(json.Find(row,"unit"));
      if(event.unit=="%" || CalendarLower(event.unit)=="percent") event.unit="percent";
      event.gold_impact_direction=CalendarGoldDirection(event);
      event.hour_alerted=false;
      event.release_alerted=false;
      int count=ArraySize(parsed);
      if(count>=CALENDAR_MAX_EVENTS || ArrayResize(parsed,count+1)<0) return false;
      parsed[count]=event;
   }
   CalendarSort(parsed);
   return CalendarCopy(events,parsed);
}

bool CalendarReadText(const int handle,string &text)
{
   if(FileTell(handle)+4>FileSize(handle)) return false;
   int size=FileReadInteger(handle,INT_VALUE);
   if(size<0 || size>CALENDAR_MAX_TEXT*4 || FileTell(handle)+(ulong)size>FileSize(handle))
      return false;
   if(size==0) { text=""; return true; }
   uchar bytes[];
   if(ArrayResize(bytes,size)<0 || FileReadArray(handle,bytes,0,size)!=(uint)size) return false;
   text=CharArrayToString(bytes,0,size,CP_UTF8);
   return StringLen(text)<=CALENDAR_MAX_TEXT;
}

bool CalendarWriteText(const int handle,const string text)
{
   if(StringLen(text)>CALENDAR_MAX_TEXT) return false;
   uchar bytes[];
   int size=StringToCharArray(text,bytes,0,WHOLE_ARRAY,CP_UTF8)-1;
   if(size<0 || FileWriteInteger(handle,size,INT_VALUE)!=4) return false;
   return size==0 || FileWriteArray(handle,bytes,0,size)==(uint)size;
}

bool ReadCalendarCache(EventInfo &events[],datetime &last_success,
                       datetime &last_attempt,bool &available)
{
   int h=FileOpen(ECONOMIC_CACHE_FILE,FILE_READ|FILE_BIN|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE) return false;
   bool ok=FileSize(h)>=36 && FileSize(h)<=CALENDAR_MAX_BYTES;
   int count=0,flag=0,source=0;
   datetime success=0,attempt=0;
   if(ok)
   {
      ok=FileReadInteger(h,INT_VALUE)==0x4D534543 && FileReadInteger(h,INT_VALUE)==2;
      count=FileReadInteger(h,INT_VALUE);
      flag=FileReadInteger(h,INT_VALUE);
      source=FileReadInteger(h,INT_VALUE);
      success=(datetime)FileReadLong(h);
      attempt=(datetime)FileReadLong(h);
      ok=ok && count>=0 && count<=CALENDAR_MAX_EVENTS && (flag==0 || flag==1) &&
         success>=0 && attempt>=success && source>=0 && source<=3;
   }
   EventInfo loaded[];
   if(ok && ArrayResize(loaded,count)<0) ok=false;
   for(int i=0;ok && i<count;i++)
   {
      ok=CalendarReadText(h,loaded[i].name) && CalendarReadText(h,loaded[i].forecast) &&
         CalendarReadText(h,loaded[i].actual) && CalendarReadText(h,loaded[i].previous) &&
         CalendarReadText(h,loaded[i].unit) && FileTell(h)+16<=FileSize(h);
      if(!ok) break;
      loaded[i].release_time=(datetime)FileReadLong(h);
      loaded[i].impact_level=FileReadInteger(h,INT_VALUE);
      loaded[i].gold_impact_direction=FileReadInteger(h,INT_VALUE);
      loaded[i].hour_alerted=false;
      loaded[i].release_alerted=false;
      loaded[i].actual=CalendarTrim(loaded[i].actual);
      if(CalendarMissing(loaded[i].actual)) loaded[i].actual="";
      if(loaded[i].unit=="%") loaded[i].unit="percent";
      ok=loaded[i].name!="" && loaded[i].release_time>0 && loaded[i].impact_level>=1 &&
         loaded[i].impact_level<=3 && loaded[i].gold_impact_direction>=-1 &&
         loaded[i].gold_impact_direction<=1;
      if(ok) loaded[i].gold_impact_direction=CalendarGoldDirection(loaded[i]);
   }
   ok=ok && FileTell(h)==FileSize(h);
   FileClose(h);
   if(!ok) return false;
   if(!CalendarCopy(events,loaded)) return false;
   last_success=success; last_attempt=attempt; available=(flag==1);
   CalendarCacheSource=source;
   return true;
}

bool WriteCalendarCache(const EventInfo &events[],const datetime last_success,
                        const datetime last_attempt,const bool available)
{
   int count=ArraySize(events);
   if(count>CALENDAR_MAX_EVENTS || last_success<0 || last_attempt<last_success ||
      CalendarCacheSource<0 || CalendarCacheSource>3) return false;
   string temporary=ECONOMIC_CACHE_FILE+".new";
   int h=FileOpen(temporary,FILE_WRITE|FILE_BIN|FILE_COMMON);
   if(h==INVALID_HANDLE) return false;
   bool ok=FileWriteInteger(h,0x4D534543,INT_VALUE)==4 &&
      FileWriteInteger(h,2,INT_VALUE)==4 && FileWriteInteger(h,count,INT_VALUE)==4 &&
      FileWriteInteger(h,available ? 1 : 0,INT_VALUE)==4 &&
      FileWriteInteger(h,CalendarCacheSource,INT_VALUE)==4 &&
      FileWriteLong(h,(long)last_success)==8 && FileWriteLong(h,(long)last_attempt)==8;
   for(int i=0;ok && i<count;i++)
   {
      ok=events[i].name!="" && events[i].release_time>0 && events[i].impact_level>=1 &&
         events[i].impact_level<=3 && events[i].gold_impact_direction>=-1 &&
         events[i].gold_impact_direction<=1 &&
         CalendarWriteText(h,events[i].name) && CalendarWriteText(h,events[i].forecast) &&
         CalendarWriteText(h,events[i].actual) && CalendarWriteText(h,events[i].previous) &&
         CalendarWriteText(h,events[i].unit) && FileWriteLong(h,(long)events[i].release_time)==8 &&
         FileWriteInteger(h,events[i].impact_level,INT_VALUE)==4 &&
         FileWriteInteger(h,events[i].gold_impact_direction,INT_VALUE)==4;
   }
   FileFlush(h);
   ok=ok && FileSize(h)<=CALENDAR_MAX_BYTES;
   FileClose(h);
   // Rename-style publication; readers reject incomplete data and tolerate read failures.
   // MQL5 does not document a cross-platform atomic replacement guarantee.
   if(ok) ok=FileMove(temporary,FILE_COMMON,ECONOMIC_CACHE_FILE,FILE_COMMON|FILE_REWRITE);
   if(!ok) FileDelete(temporary,FILE_COMMON);
   return ok;
}

#endif
