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
cleans up only its own canvas, borders, labels, confirmation arrows, and RSI label.

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
