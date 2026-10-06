# Market-Sessions-Indicator
MQL5 indicator that draws boxes around Asian, London, and NY trading sessions with M15 breakout colors and customizable transparency

## Installation

1. In MetaTrader 5, select **File → Open Data Folder**.
2. Copy `Market_Sessions_Boxes.mq5` into `MQL5/Indicators`.
3. Open the file in MetaEditor and compile with **F7**. The included
   `Canvas/Canvas.mqh` is part of MT5's standard library; no downloads are needed.
4. Refresh **Navigator → Indicators** and attach **Market Sessions Boxes** to a chart.

## Defaults and inputs

| Session | Open | Close |
| --- | --- | --- |
| Asian | 00:00 | 08:00 |
| London | 10:00 | 14:00 |
| NY | 14:30 | 21:00 |

Hours are **GMT+2 winter reference times**, not the current broker clock.
The defaults preserve the previous winter schedule. Boxes and opening-time
labels are converted automatically to broker server time for each date.
Each session has separate opening/closing hour and minute and
transparency inputs. Transparency ranges from **0 (opaque) to 100 (invisible
fill)**; borders and labels match the block's signal color. The default is 85.
The former per-session color inputs are replaced by automatic gray/green/red colors.

- Show or hide session names; optionally append their opening times.
- Set border width (1–5 pixels) and history (1–30 calendar days, default 5).
- Hours must be 0–23 and minutes 0–59. Equal opening/closing times are rejected.
  A closing time before the opening time represents an overnight session.

## Timezones and automatic DST

- `InpBrokerUTCOffset` is the broker's **standard/non-DST UTC offset in hours**
  (default `2.0`, range -14 to +14). Fractional offsets such as `5.5` or `5.75`
  are supported, rounded to the nearest minute.
- `InpDetectBrokerOffset` (default `true`) measures the live offset using
  `TimeTradeServer() - TimeGMT()` and subtracts the configured broker DST advance
  to infer the standard offset. It refreshes automatically. This needs a correct
  computer clock/timezone; disable it to use `InpBrokerUTCOffset` explicitly.
  Detection is disabled in the strategy tester, where MT5's `TimeGMT()` equals
  simulated server time; the configured base offset is used there. Detection
  is also disabled for Australia/NZ: their local transition instants require
  a known standard offset and a single live reading is ambiguous at fall-back.
  Set the correct `InpBrokerUTCOffset` for these presets; DST is still automatic.
- `InpBrokerDSTRule` selects the broker's clock-change policy. The default is
  `BROKER_DST_EUROPE`. Choose **`BROKER_DST_NONE` for a fixed-offset broker**.
  `BROKER_DST_US` is for brokers switching at New York's transition instants
  (including many GMT+2/+3 brokers), not necessarily at their own local 02:00.
  `BROKER_DST_AUSTRALIA` and `BROKER_DST_NZ` use local transition times.
- `InpBrokerDSTMinutes` is the broker's DST clock advance (default 60, range
  1–120); it is ignored for `BROKER_DST_NONE`.

The broker's current offset **cannot identify its historical DST policy**.
Select the rule matching your broker once; subsequent transitions require no
manual changes. Brokers with a custom calendar outside these presets require
an explicit fixed offset (`BROKER_DST_NONE`, detection disabled) and manual
updates when their clocks change. Do not select Europe merely because the
broker's winter offset is GMT+2.

London follows the UK/European rule: DST starts on the last Sunday in March
at 01:00 UTC and ends on the last Sunday in October at 01:00 UTC. New York
follows the modern US rule (2007 onward): second Sunday in March at 07:00 UTC
through first Sunday in November at 06:00 UTC. Australian DST runs from the
first Sunday in October at local standard 02:00 to the first Sunday in April
at local daylight 03:00; New Zealand starts on the last Sunday in September
at local standard 02:00 and ends on the first Sunday in April at daylight 03:00.
These presets model recurring rules, not a historical timezone database.

Asian hours remain fixed in UTC (the default is 22:00–06:00 UTC). London
and NY inputs retain their respective local wall-clock schedules: the defaults
are London 08:00–12:00 local and New York 07:30–14:00 local. To customize them,
enter the desired winter time converted to GMT+2 (London local +2 hours,
New York local +7 hours). Each opening and closing endpoint uses its own date
and DST state, including overnight sessions. During spring-forward, nonexistent
regional times move into the following hour; at fall-back the first occurrence
is used. Intervals collapsing to zero or negative server-clock duration are skipped.

For example, with detection disabled and a fixed GMT+2 broker, the summer
defaults become Asian 00:00–08:00, London 09:00–13:00, NY 13:30–20:00.
With a GMT+2/+3 **European-rule** broker, when both regions are in DST they
become Asian 01:00–09:00, London 10:00–14:00, NY 14:30–21:00. In the weeks
when only the US is in DST, NY is 13:30–20:00 on that broker. History is
converted per date, never using today's DST state for all past boxes.

## Behavior

Ranges use the symbol's **M1 highs/lows**, regardless of the chart timeframe.
The opening minute is included; the closing minute is excluded. Active boxes
extend to the scheduled close, but their price range uses only available data
through the latest server quote. Future sessions and sessions without bars
(such as weekends) are not drawn. Overnight sessions from the preceding day
are retained when they intersect the configured history window.

All boxes remain **gray** during the session and while awaiting confirmation.
After the session closes, each **completed M15 candle** after the close is
checked in order until one breaks the range. The first candle whose **close
price** is strictly above the session high turns the box **green** (buy);
strictly below the session low turns it **red** (sell). Wicks, equality with
either boundary, and closes inside the range do not signal a break; monitoring
continues with the next candle. The M15 candle that confirmed the break is
marked with a small **orange arrow**: pointing up from just below its low for
green (buy) breaks, pointing down from just above its high for red (sell) breaks.
The final range and color are retained until the session leaves the configured
history window. Historical sessions are evaluated the same way when loaded.

The top-right corner shows the current **RSI(14, close)** of H1, M15 and M5:
`H1 RSI: XX.XX | M15 RSI: XX.XX | M5 RSI: XX.XX`, regardless of the chart
timeframe. Values include the forming candle and refresh on **every tick**,
not only on candle closes; `--` is shown while a timeframe's history is still loading.

The indicator refreshes every 60 seconds and on each new chart bar, and
repositions fills when the chart is scrolled, zoomed, or resized. M1 history
may need to download before boxes appear; M15 history may also need to download
before confirmation. The timer retries automatically.
Ranges are limited to the minute history supplied by your broker. Between
quotes, the server timestamp remains the last known quote time.

Real transparency is rendered with MT5's standard ARGB canvas, with native
chart objects for borders and labels. Overlapping custom sessions are painted
in chronological order, with Asian/London/NY order for the same opening day;
the last fill takes precedence in overlapping pixels. Multiple indicator
instances use separate object names. Removing or reconfiguring an instance
cleans up only its own canvas, borders, labels, confirmation arrows, and RSI label.

## Manual verification (MetaTrader 5)

This repository has no automated test infrastructure. Compilation and visual
verification require MetaEditor/MT5.

1. Compile with F7 and check for errors/warnings, then attach to an M1 chart
   with available history. Configure the broker timezone/rule and confirm the
   adjusted times and labels against the examples above.
2. Compare each box's high/low with M1 candles in `[open, close)`. Check that
   a spike in the closing minute does not affect the preceding session.
3. Switch to M5/H1: ranges should stay the same, including NY's 14:30 start.
4. During an active session, check range expansion after a new bar or the
   next minute update, and no expansion from prices after the session close.
5. Try transparency 0/85/100, toggle labels/time labels, and zoom, scroll,
   and resize. Borders should remain anchored to the session times and range.
6. Set an overnight interval (e.g. 22:00–02:00), and inspect both sides of
   midnight. Verify no boxes for future sessions or days without trading.
7. Attach two instances, then remove one: the other instance and unrelated
   chart objects must remain. Invalid times, transparency, history length,
   and border width should reject initialization with a diagnostic.
8. Observe an active session and its first post-session M15 candle: the box,
   border, and label must remain gray until that candle closes. Check a close
   above the session high (green) and one below the low (red), on M1 and H1 charts.
9. Check wick-only breaks, closes exactly on either boundary, and in-range
   closes: they do not signal; the first later M15 close outside the range does.
10. Set a close between M15 openings (e.g. 08:07): ignore the 08:00 candle and
   start with 08:15 after it closes. Also check an overnight session and a
   trading gap.
11. After confirmation, refresh, zoom, scroll, and wait across midnight: colors
   must persist within the history window. Reattach the indicator and confirm
   historical colors match the same rule.
12. On an M15 chart, verify the small orange arrow marks exactly the candle
   whose close first left the range: up arrow under green breaks, down arrow
   over red breaks.
13. Compare the RSI label with standard RSI(14) indicators on H1, M15 and M5
   charts; values change on every tick, including mid-candle.
14. In the strategy tester, use a fixed GMT+2 broker (`BROKER_DST_NONE`) and
   check March 6/9/30, 2026: London opens at 10:00/10:00/09:00 and NY at
   14:30/13:30/13:30. Check October 23/26 and November 2: London opens at
   09:00/10:00/10:00 and NY at 13:30/13:30/14:30. Asian stays at 00:00.
15. Repeat with a GMT+2 European-rule broker: March 30 should show Asian
   01:00, London 10:00, NY 14:30; March 9 still shows NY 13:30.
   With a US-rule broker on March 9, expect Asian 01:00, London 11:00,
   NY 14:30. Keep 30 days visible across transitions to verify older boxes
   retain the offsets for their dates after refreshing or reattaching.
16. Disable detection and try fixed offsets -5, +5.5, +5.75, and +14.
   Verify minute offsets, date rollovers, and overnight sessions intersecting
   the oldest displayed day. Test Australia/NZ across September/October and
   April, including a year boundary. Invalid offsets/DST advances must reject
   initialization. Compare live detection with an explicitly configured offset.
