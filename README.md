# Market-Sessions-Indicator
MQL5 indicator that draws boxes around Asian, London, and NY trading sessions with customizable colors and transparency

## Installation

1. In MetaTrader 5, select **File → Open Data Folder**.
2. Copy `Market_Sessions_Boxes.mq5` into `MQL5/Indicators`.
3. Open the file in MetaEditor and compile with **F7**. The included
   `Canvas/Canvas.mqh` is part of MT5's standard library; no downloads are needed.
4. Refresh **Navigator → Indicators** and attach **Market Sessions Boxes** to a chart.

## Defaults and inputs

| Session | Open | Close | Color |
| --- | --- | --- | --- |
| Asian | 00:00 | 08:00 | Dodger blue |
| London | 10:00 | 14:00 | Lime green |
| NY | 14:30 | 21:00 | Orange-red |

All hours are **broker server time**, assumed GMT+2. There is no timezone or
daylight-saving conversion: adjust the inputs if your broker's clock differs.
Each session has separate opening/closing hour and minute, color, and
transparency inputs. Transparency ranges from **0 (opaque) to 100 (invisible
fill)**; borders and labels retain the selected color. The default is 85.

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

The indicator refreshes every 60 seconds and on each new chart bar, and
repositions fills when the chart is scrolled, zoomed, or resized. M1 history
may need to download before boxes appear; the timer retries automatically.
Ranges are limited to the minute history supplied by your broker. Between
quotes, the server timestamp remains the last known quote time.

Real transparency is rendered with MT5's standard ARGB canvas, with native
chart objects for borders and labels. Overlapping custom sessions are painted
in chronological order, with Asian/London/NY order for the same opening day;
the last fill takes precedence in overlapping pixels. Multiple indicator
instances use separate object names. Removing or reconfiguring an instance
cleans up only its own canvas, borders, and labels.

## Manual verification (MetaTrader 5)

This repository has no automated test infrastructure. Compilation and visual
verification require MetaEditor/MT5.

1. Compile with F7 and check for errors/warnings, then attach to an M1 chart
   with available history. Confirm the default times, colors, and labels.
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
