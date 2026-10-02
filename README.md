# Market-Sessions-Indicator
MQL5 indicator that draws boxes around Asian, London, and NY trading sessions with M15 breakout colors and customizable transparency

## Installation

1. In MetaTrader 5, select **File → Open Data Folder**.
2. Copy `Market_Sessions_Boxes.mq5` and `EconomicCalendar.mqh` into `MQL5/Indicators`.
3. Open the file in MetaEditor and compile with **F7**. The included
   `Canvas/Canvas.mqh` is part of MT5's standard library; no downloads are needed.
4. Refresh **Navigator → Indicators** and attach **Market Sessions Boxes** to a chart.

### Economic calendar setup

The overlay is part of **Market Sessions Boxes**, not a separate indicator.
MT5 [prohibits `WebRequest` in indicators](https://www.mql5.com/en/docs/network/webrequest)
(error 4014), so a small **non-trading companion EA** updates the shared calendar.
By default it uses [MT5's free built-in economic calendar API](https://www.mql5.com/en/docs/calendar),
which includes released actuals without a third-party key. Its coverage and
availability depend on the terminal's calendar service.

1. Copy `EconomicCalendar.mqh` alongside `Market_Sessions_Boxes.mq5` in
   `MQL5/Indicators`. Copy `Market_Sessions_Calendar_Fetcher.mq5` and another
   copy of `EconomicCalendar.mqh` into `MQL5/Experts`.
2. Compile both `.mq5` files with F7. Attach **one** fetcher EA to a spare chart
   and leave that chart open. Terminals sharing the same common data folder
   also share this writer; a second fetcher is rejected. It never places orders. Enable the terminal's
   Algo Trading/EA permissions as needed for its timer to run.
3. Under **Tools → Options → Expert Advisors → Allow WebRequest for listed URL**,
   add `https://nfs.faireconomy.media`. The no-key HTTP fallback is
   [Forex Factory's weekly JSON calendar](https://nfs.faireconomy.media/ff_calendar_thisweek.json):
   no key is required.
4. Set `UseMT5Calendar=false` on the fetcher to use the HTTP feed alone.
   **Important:** that public feed contains schedules, forecasts, and previous
   values, **not released actuals**. It covers the current week only; missing
   forecasts stay `--`. Gold bias therefore remains neutral and actual-release
   alerts are unavailable with this feed alone. The indicator never invents results.
   If native access fails after a successful native update, the last-known
   native data is retained rather than overwritten by a schedule-only feed.
5. As an alternative actual-versus-forecast source, configure the fetcher's optional Fin2Dev
   key and whitelist `https://apidata.fin2dev.com`. Get your own key via
   [Fin2Dev](https://fin2dev.com/pricing/); authentication is a single key, but
   current access, quotas, and free-tier eligibility must be checked with the
   provider. See its [response schema](https://github.com/fin2dev/Economic-Calendar-API).
   The fetcher uses the provider's default calendar window, not its PRO-only
   date-range filter; available upcoming dates depend on the subscription.
   Fin2Dev's documented timestamps do not specify a timezone: confirm it with
   your provider and set the fetcher's UTC-offset input accordingly. Zero
   assumes UTC. Do not publish keys in source code, screenshots, or presets.
   Its numeric impact mapping is also configurable: `Fin2DevImpactOneIsHigh=true`
   assumes 1/2/3 = high/medium/low; confirm this with the provider and reverse it
   if necessary.

The EA fetches every **30 minutes** by default (configurable to 30–60).
All charts read the same versioned `MarketSessionsCalendar.bin` cache in
**Terminal Common Data Folder → Files** once per minute. API failures preserve
last-known events and show an unavailable/stale status rather than blanking
the display. Data older than two hours is marked stale. Actual results and
release alerts can lag by the polling interval and the provider's own delay;
this is not a tick-by-tick news service. No network requests run on the
indicator's shared thread. Live calendar retrieval requires a running terminal,
not the Strategy Tester.

## Economic events and gold bias

- **US/USD:** CPI/core inflation/PCE, NFP/non-farm payrolls, Fed/FOMC rate
  decisions and announcements, unemployment, retail sales, PPI, Treasury
  auctions, jobless claims, and GDP/recession data.
- **Euro area/EUR:** ECB announcements and rate decisions.
- **China/CNY:** manufacturing and services PMI.

These are gold-relevant events, not all necessarily denominated in USD.
Only events actually supplied by the selected provider can be displayed.
Upcoming events and the last 24 hours of releases are visible on **every
timeframe**, including M1, M5, M15 and H1, without M15 confirmation.

Stacked labels show, for example:

```text
Core CPI | Forecast: 3.2% | Time: 45 min | Impact: HIGH
2026.10.02 12:30 UTC | Gold: → Neutral
Core CPI | Forecast: 3.2% | Actual: 3.4% | Surprise: +0.20 pp (+6.25%) | Impact: HIGH
2026.10.02 12:30 UTC | Gold: ↓ Bearish
```

Impact text is red for **HIGH**, yellow/gold for **MED**, green for **LOW**.
Emoji appearance depends on the terminal's fonts. Gold arrows have their own
color: **red ↓ Bearish**, **green ↑ Bullish**, or **→ Neutral**. Labels do not
overlap; use **Previous/Next** when the full feed exceeds the chart height.
All events remain available on each timeframe, even when not on the current
page. Widen the chart to read long event names.

Surprise is **actual − forecast**, plus the relative surprise
`(actual − forecast) / abs(forecast) × 100` when forecast is nonzero.
Percent data differences use **percentage points (pp)**. Missing or nonnumeric
values show `--`, not a fabricated zero.

Bias is a **simple economic heuristic, not an AI prediction or trading signal**:

- Stronger-than-forecast US inflation, payrolls, retail sales, or growth:
  bearish gold; weaker data: bullish gold; equal results: neutral.
- Unemployment/jobless claims invert that rule: higher is weaker employment
  and bullish gold.
- Fed rate hikes/cuts compare actual with the **previous rate**, when supplied,
  so an expected hike still reads bearish and an expected cut bullish.
- Released China PMI below 50, negative GDP growth (not GDP price indexes),
  and explicit affirmative recession reports are treated as bullish
  recession/safe-haven signals, overriding the surprise rule.
- ECB statements and Treasury auctions remain neutral without a reliable
  directional rule; missing actuals/forecasts cannot establish a surprise.

Actual gold prices may move differently because of expectations, revisions,
positioning, yields, or geopolitical news.

Light gray background strips cover **30 minutes before** each event; gold
strips cover **30 minutes after** (configurable to 15–30). They span the chart's
height and are painted behind session boxes. Intrabar time interpolation keeps
short windows visible even on H1. Labels/countdowns use **UTC**; zone anchors
convert UTC to broker time. Automatic broker-offset detection uses
`TimeTradeServer() − TimeGMT()` and depends on the computer's correct clock.
Disable it and set `InpBrokerUTCOffsetMinutes` manually if necessary, including
after broker daylight-saving changes. Native calendar timestamps are converted
using the current broker offset throughout the fetch window; a window spanning
a broker daylight-saving transition may need time checks on either side.

Journal alerts fire once per event per attached instance while it is within
one hour, and once when a released actual first becomes available. Reattaching
an indicator resets those flags; multiple charts can each print an alert.
Set `InpEconomicAlerts=false` to suppress duplicates, or
`InpShowEconomicEvents=false` to disable the overlay. Events more than 24 hours
old are pruned; removing an indicator deletes only its own calendar labels,
buttons, and canvas zones along with its session objects.

## Defaults and inputs

| Session | Open | Close |
| --- | --- | --- |
| Asian | 00:00 | 08:00 |
| London | 10:00 | 14:00 |
| NY | 14:30 | 21:00 |

All hours are **broker server time**, assumed GMT+2. There is no timezone or
daylight-saving conversion: adjust the inputs if your broker's clock differs.
Each session has separate opening/closing hour and minute and
transparency inputs. Transparency ranges from **0 (opaque) to 100 (invisible
fill)**; borders and labels match the block's signal color. The default is 85.
The former per-session color inputs are replaced by automatic gray/green/red colors.

- Show or hide session names; optionally append their opening times.
- Set border width (1–5 pixels) and history (1–30 calendar days, default 5).
- Hours must be 0–23 and minutes 0–59. Equal opening/closing times are rejected.
  A closing time before the opening time represents an overnight session.

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
and economic-calendar objects.

## Manual verification (MetaTrader 5)

This repository has no automated test infrastructure. Compilation and visual
verification require MetaEditor/MT5.

1. Compile with F7 and check for errors/warnings, then attach to an M1 chart
   with available history. Confirm the default times and labels.
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

### Economic calendar verification (live MT5)

1. Compile the indicator and fetcher without errors/warnings. Start the EA
   with native calendar enabled; confirm upcoming CPI/NFP/FOMC entries when they are
   present that week, forecasts, impact colors, UTC dates, and countdowns.
   Disable native access and clear the cache after stopping the EA to test the
   no-key JSON feed alone: actuals must remain unavailable for that schedule-only feed.
2. Attach the indicator to M1, M5, M15, and H1 for the same symbol. Compare
   event names/times and countdowns. Resize to a short chart and navigate
   Previous/Next: all entries should remain accessible without overlapping rows.
3. Around a known release, compare its UTC time with the provider and broker
   clock. Verify the gray 30-minute pre-event strip and gold 15/30-minute
   post-event strip on all four timeframes, including fractional H1 widths.
   Scroll, zoom, and change the broker offset; session boxes/RSI must be unchanged.
4. With native calendar or actual-capable provider access, observe CPI, NFP, and a Fed decision.
   After the next fetch, check actual/forecast/previous against the source:
   hotter CPI/stronger NFP are bearish, weaker results bullish, equal results
   neutral. Verify a rate hike versus previous is bearish even when expected.
   Higher unemployment/claims must be bullish; missing values stay neutral.
5. Check positive/negative/zero forecasts, percent and K/M-suffixed figures:
   surprises must be signed, percentage-point units correct, and zero forecasts
   must not cause division by zero. Auctions/ECB statements should not invent
   bias from incomparable numbers.
6. Within an hour of a future release, check the journal for one alert per
   instance; repeated minute ticks should not repeat it. Confirm one actual
   release alert after results arrive, not merely when the clock passes release.
7. Remove the whitelist or disconnect after a successful fetch. At the next
   attempt, confirm last-known labels remain with API-unavailable status.
   Restore access and verify recovery. Start without a cache to check the
   fetcher setup hint; malformed/error responses must not erase a good cache.
8. Leave the EA running through a release/day/week rollover. Verify 30–60-minute
   network spacing, no per-chart extra requests, preserved released actuals,
   and removal of events older than 24 hours. Switch timeframes and remove one
   of two indicator instances: no calendar objects should be orphaned, and the
   remaining instance/session boxes should continue to work.
