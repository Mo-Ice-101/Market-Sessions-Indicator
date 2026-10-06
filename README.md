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

Asian and London hours are **GMT+2 winter reference times**; NY hours are
**UTC winter reference times**, not the current broker clock. NY's default
14:30 represents the NYSE's 09:30 EST opening. Boxes and opening-time labels
are converted automatically to broker server time for each date.
Each session has separate opening/closing hour and minute and
transparency inputs. Transparency ranges from **0 (opaque) to 100 (invisible
fill)**; borders and labels match the block's signal color. The default is 85.
The former per-session color inputs are replaced by automatic gray/green/red colors.

- Show or hide session names; optionally append their opening times.
- Set border width (1–5 pixels) and history (1–30 calendar days, default 5).
- Hours must be 0–23 and minutes 0–59. Equal opening/closing times are rejected.
  A closing time before the opening time represents an overnight session.

## Timezones and automatic DST

- `InpDetectBrokerOffset` (default `true`) automatically measures
  `TimeTradeServer() - TimeGMT()` while connected and receiving recent quotes.
  No broker timezone configuration is needed for the live offset. This requires
  a correct computer clock/timezone. Disconnected or stale quotes are not sampled.
- Observations are saved once per UTC day and whenever the offset changes, in a
  broker-server-specific `MSB_Offsets_*.csv` file in the terminal's `MQL5/Files`
  sandbox. At startup the indicator reloads the last 370 days of observations.
  Equal January/July offsets with no observed changes select `BROKER_DST_NONE`.
  Changed offsets are compared against Europe, US, Australia and NZ rules; a
  rule is selected only when exactly one matches all recent observations.
  The observed clock advance is detected too.
- A separate label below the RSI shows the broker's current UTC offset and DST
  policy, with spacing based on the RSI text height and display scaling.
  **DST: unverified** means there is insufficient or ambiguous evidence. The
  current offset is used provisionally, with recorded offsets used for earlier
  observed dates. Dates before the first observation use the current offset.
  Consequently historical boxes can be inaccurate across an unobserved clock
  change until the policy is learned or an explicit fallback is configured.
- MT5 does **not** provide historical UTC offsets for arbitrary winter/summer
  dates: candle/tick timestamps alone cannot supply them. A first installation
  cannot instantly determine a broker's DST policy. January/July readings alone
  also cannot distinguish Europe from US; observations near their differing
  transition dates are needed. Detection models recurring rules, not arbitrary
  broker policy changes. Keep the indicator running to collect evidence.
- Manual inputs remain as an optional fallback: disable `InpDetectBrokerOffset`,
  set `InpBrokerUTCOffset` to the **standard/non-DST offset in hours** (default
  `2.0`, range -14 to +14; fractional offsets supported), `InpBrokerDSTRule`
  (default `BROKER_DST_NONE`), and `InpBrokerDSTMinutes` (default 60, range 1–120).
  The strategy tester always uses these inputs because its `TimeGMT()` equals
  simulated server time; it neither reads nor writes live observations.
  Its default is now fixed UTC+2, rather than the previous European DST preset;
  select the intended broker rule explicitly when comparing backtests.
  `BROKER_DST_US` switches at New York's UTC transition instants, including for
  GMT+2/+3 brokers; Australia/NZ use local transition times.

London always follows the UK/European rule, independently of broker detection:
DST starts on the last Sunday in March
at 01:00 UTC and ends on the last Sunday in October at 01:00 UTC. New York
always follows the modern US rule (2007 onward), independently of the broker:
second Sunday in March at 07:00 UTC
through first Sunday in November at 06:00 UTC. Australian DST runs from the
first Sunday in October at local standard 02:00 to the first Sunday in April
at local daylight 03:00; New Zealand starts on the last Sunday in September
at local standard 02:00 and ends on the first Sunday in April at daylight 03:00.
These presets model recurring rules, not a historical timezone database.

Asian hours remain fixed in UTC (the default is 22:00–06:00 UTC). London
and NY inputs retain their respective local wall-clock schedules: the defaults
are London 08:00–12:00 local and New York 09:30–16:00 local. To customize them,
enter the desired winter time converted to GMT+2 for London (local +2 hours)
or UTC for New York (local +5 hours). Regional DST is applied before adding
the broker's date-specific UTC offset; a broker with no DST still gets the
UK/US session adjustments. Each opening and closing endpoint uses its own date
and DST state, including overnight sessions. NY checks US DST at its UTC winter
reference, subtracts one hour when active, then applies the broker offset.
London's nonexistent spring-forward times move into the following hour; at
fall-back the first occurrence is used. Intervals collapsing to zero or negative
server-clock duration are skipped.

For example, with detection disabled and a fixed GMT+2 broker, the summer
defaults become Asian 00:00–08:00, London 09:00–13:00, NY 15:30–22:00.
In winter on that SAST (UTC+2, no DST) broker they are Asian 00:00–08:00,
London 10:00–14:00, NY 16:30–23:00.
With a GMT+2/+3 **European-rule** broker, when both regions are in DST they
become Asian 01:00–09:00, London 10:00–14:00, NY 16:30–23:00. In the weeks
when only the US is in DST, NY is 15:30–22:00 on that broker. History is
converted per date, never using today's DST state for all past boxes.

NY inputs previously used GMT+2 winter references. The corrected conversion
shifts existing NY inputs two hours later; to preserve a custom NY local
schedule, subtract two hours from its old opening and closing inputs.

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
cleans up only its own canvas, borders, labels, confirmation arrows, RSI label,
and timezone label, including after partial initialization failures.

## Manual verification (MetaTrader 5)

### NY debug logging

The **Experts** tab contains `NY DEBUG:` messages on every `UpdateSessions()`
call and every NY opening/closing conversion, including reference dates that
are later skipped for rendering. Each conversion logs the dated input,
UTC after the GMT+2 step (no subtraction for NY), US DST status, the
0/3600-second DST subtraction, UTC before the broker offset, the offset in
minutes/seconds, and final server time. Update messages identify opening and
closing references, converted times, and the opening-label time.

`Expected (ref - US DST + broker)` checks the arithmetic using the reported
DST state and broker offset; it does not independently verify their correctness.
`Expected SAST (fixed UTC+2)` is a separate comparison, not an assumption about
the broker. For a summer 14:30 reference, expect UTC 13:30 and SAST 15:30;
a broker offset of 180 minutes legitimately produces server time 16:30.
In winter, expect UTC 14:30 and SAST 16:30. Check both endpoints, overnight
date rollovers, and the DST boundary dates below. Logs are unconditional and
can be verbose across the configured history window; calculations are unchanged.

This repository has no automated test infrastructure. Compilation and visual
verification require MetaEditor/MT5.

1. Compile with F7 and check for errors/warnings, then attach to an M1 chart
   with available history. Leave automatic detection enabled and compare the
   chart's broker UTC offset with server time minus UTC. On a fresh installation,
   check that DST is reported as unverified, rather than a guessed Europe rule.
2. Compare each box's high/low with M1 candles in `[open, close)`. Check that
   a spike in the closing minute does not affect the preceding session.
3. Switch to M5/H1: ranges and converted NY opening times should stay the same.
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
   charts; values change on every tick, including mid-candle. Check that the
   broker offset and DST status occupy a separate line below the RSI without
   overlap, including at higher display scaling and after resizing the chart.
14. In the strategy tester, use a fixed GMT+2 broker (`BROKER_DST_NONE`) and
   check March 6/9/30, 2026: London opens at 10:00/10:00/09:00 and NY at
   16:30/15:30/15:30. Check October 23/26 and November 2: London opens at
   09:00/10:00/10:00 and NY at 15:30/15:30/16:30. Asian stays at 00:00.
   For NY transition boundaries on that fixed UTC+2 broker, use custom inputs:
   March 8 at 06:59/07:00 UTC winter reference must convert to 08:59/08:00;
   November 1 at 05:59/06:00 must convert to 06:59/08:00.
   With time labels enabled, verify each label matches its rectangle's opening
   timestamp in the Objects List: summer NY must show `NY 15:30` on fixed UTC+2,
   and winter NY `NY 16:30`. Edit an existing NY label's text to an incorrect
   time, then wait for the next session update: it must restore the box's time.
   Check that London/Asian names and times still match their box openings;
   disabling time labels must leave only the session names.
15. Repeat with a GMT+2 European-rule broker: March 30 should show Asian
   01:00, London 10:00, NY 16:30; March 9 still shows NY 15:30.
   With a US-rule broker on March 9, expect Asian 01:00, London 11:00,
   NY 16:30. Also check a fixed UTC+3 broker: winter openings are Asian
   01:00, London 11:00, NY 17:30; summer openings are 01:00, 10:00, 16:30.
   Keep 30 days visible across transitions to verify older boxes
   retain the offsets for their dates after refreshing or reattaching.
16. Disable detection and try fixed offsets -5, +5.5, +5.75, and +14.
   Verify minute offsets, date rollovers, and overnight sessions intersecting
   the oldest displayed day. Test Australia/NZ across September/October and
   April, including a year boundary. Invalid offsets/DST advances must reject
   initialization. Compare live detection with an explicitly configured offset.
17. Reattach with automatic detection enabled and check that observations reload.
   Compare recorded January/July offsets: unchanged offsets select None; changed
   offsets remain unverified until the transition-date evidence uniquely selects
   a rule. Compare London/NY times on fixed GMT+2 and seasonal GMT+2/+3 brokers:
   their regional rules must not change with the detected broker policy.
18. Disconnect the terminal or wait through a weekend without fresh quotes:
   no new offset observations should be saved. A fresh instance without a live
   measurement shows "waiting for live quotes" and waits before drawing boxes.
   Remove each instance and check the Objects List (including hidden objects):
   no owned objects should remain, and other instances/manual drawings survive.
