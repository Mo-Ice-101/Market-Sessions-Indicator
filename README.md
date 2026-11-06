# Market-Sessions-Indicator
MQL5 opening-M15 range indicator with M5 breakout colors, high/midpoint/low
levels to the next session, and a two-entry hedging-account EA.

## Installation

1. In MetaTrader 5, select **File → Open Data Folder**.
2. Copy `Market_Sessions_Boxes.mq5` into `MQL5/Indicators`.
3. Copy `Market_Sessions_Core.mqh` into the same directory as the indicator.
   Open the indicator in MetaEditor and compile with **F7**. The included
   `Canvas/Canvas.mqh` is part of MT5's standard library; no downloads are needed.
4. Refresh **Navigator → Indicators** and attach **Market Sessions Boxes** to a chart.

## Expert Advisor

`Market_Sessions_EA.mq5` is a separate trading EA; the indicator remains available.
Both use `Market_Sessions_Core.mqh` for regional DST, opening M15 ranges and M5 breakout
confirmation. The EA does not require the indicator on the chart and does not
draw session boxes. Attach the indicator separately for visualization.

Copy the EA and `Market_Sessions_Core.mqh` together into `MQL5/Experts`, then
compile the EA with F7. Run it in Strategy Tester and on a demo account before
enabling live algorithmic trading.

### Enable or disable EA entries

`InpEnableEA` defaults to **true**. Set it to **false** to block new market
and midpoint entries and cancel this EA's unfilled midpoint orders on the
next tick/timer event. Cancellation requires connectivity and algorithmic
trading permission; rejected cancellations are logged and retried.
Existing filled positions continue their independent 2R exits, break-even
and ATR trailing for safety, even while entries are disabled.
For indicator-only use with no EA management, attach only
`Market_Sessions_Boxes.mq5`; the indicator never places trades.

### Sync the MQL5 source locally

```sh
git clone --branch feat/opening-range-hedging-ea https://github.com/Mo-Ice-101/Market-Sessions-Indicator.git
```

For an existing checkout on this branch, use `git pull --ff-only`.
Copy `Market_Sessions_Boxes.mq5` and `Market_Sessions_Core.mqh` together into
`MQL5/Indicators`, and `Market_Sessions_EA.mq5` and the header together into
`MQL5/Experts`. Recopy after pulling updates, then compile both `.mq5` files
in MetaEditor with F7. Git pull alone does not update the terminal folders.

### Entry and management

- Asian, London and NY can be enabled independently. Their schedules and
  reference timezones match the indicator. The EA requires an **explicit broker
  standard UTC offset and DST rule** in both live trading and backtesting;
  it does not learn offsets from the live clock. For matching visuals, disable
  automatic detection on the indicator and use the same timezone inputs.
- After the first complete M15 candle at/after a session opening, the first
  subsequent M5 close strictly above/below that candle's range confirms a
  buy/sell. Wicks and boundary equality do not signal. RSI is not a filter.
- Each opening range can create one **high-risk market entry** and one
  **medium-risk limit entry at its 50% midpoint**, in the same direction.
  Midpoint placement follows a confirmed market fill. Rejected requests are
  logged, not queued; if midpoint placement fails, the market trade retains
  its protective stop. "Medium risk" describes entry style, not lower sizing.
- A **hedging account is required**. Earlier sessions' EA positions do not
  block new opening-range pairs: every entry keeps its own original R, 2R exit
  and ATR trail across all later sessions. Manual/other-EA exposure on the
  symbol and unresolved immediate market requests block new pairs.
  Simultaneous signals use reference-date order, then Asian/London/NY order.
- Unfilled midpoint limits expire at the next scheduled session opening,
  including disabled sessions and calendar weekends. Broker-side specified
  expiry is preferred; GTC fallback uses an expiry timestamp in the order
  comment and EA timer/tick cancellation. Keep the terminal running/connected
  and trading enabled for that fallback; offline expiry cannot be guaranteed.
  Session boundaries never close filled trades or reset their trailing stops.
- `InpDaysToMonitor` defaults to the indicator's five-calendar-day horizon.
  Older sessions expire. Only confirmations in the immediately preceding M5
  candle are eligible: starting/restarting the EA never enters historical
  signals. Missing history is retried within the current M5 candle; signals
  missed before history arrives are not traded late. The first M5 candle
  closing after startup can signal.
- Both entries use initial SL **10 symbol points beyond the opposite M15
  range boundary**: below its low for buys, above its high for sells.
  `InpStopBufferPoints` is adjustable. This is not a 10-point distance from
  entry or an ATR initial stop. Prices round outward to tradable ticks.
  Broker stop-distance violations reject the pair rather than widen the stop.
- **R** is actual filled entry price minus the original protective stop distance
  (the reverse for sells). At **2R**, measured using executable bid for buys
  and ask for sells, the EA closes **50% of the original filled volume**.
  It then moves the remaining stop to entry or better and trails it at
  **2 × the latest completed M15 ATR(14)**. There is no fixed final take profit.
  Trailing is checked every tick, never loosens an existing stop, and cannot
  move beyond break-even toward a loss. Break-even is price-based and does
  not include commission or swap.
- Broker history supplies original entry, initial SL and completed scale-out
  volume after restart, so moving the stop does not redefine R or repeat the
  half-close. Once 2R is reached, the scale-out remains armed across retracements
  and rejected requests. Live 2R markers are stored in account/magic/position-
  scoped terminal global variables and removed after closure; tester runs use
  only in-memory markers and never read/write live markers. Partial execution
  is reconciled before requesting the remaining half. Resting midpoint limits
  do not block trailing or exits; unresolved immediate market requests do.
  Missing/inconsistent history or externally changed positions suspend
  management with an Experts-tab diagnostic; the existing broker SL remains.
  Do not share the magic number with another EA or manually alter its position.
- Each hedged position uses ticket-targeted reductions. The symbol
  must support immediate FOK or IOC filling (FOK preferred). Stops, freeze
  levels, volume steps and minimum remaining lots are respected. A rejected
  half-close or blocked break-even/trail is logged and retried on later ticks.
  A retracement, broker restriction or execution failure can prevent protection
  at break-even; the EA cannot guarantee a risk-free remainder.

### Sizing and inputs

Choose `InpSizing = SIZE_EQUITY_PERCENT` or `SIZE_FIXED_LOTS`.
Percentage sizing defaults to **0.5% of current equity**; fixed size defaults
to **0.10 lots**. Both are user-adjustable and apply **separately to each
entry**, not split between them. Combined intended risk can reach twice the
selected percentage (or twice the selected lots), plus existing sessions'
remaining exposure. Both risk budgets use equity at the signal time.
Percentage sizing uses
`OrderCalcProfit` in account currency and includes the configured adverse
deviation allowance for market entries (limit entries use their limit price),
then rounds **down** to a volume divisible into two valid
equal halves. It never rounds up to meet minimum lots. Fixed lots must already
be a valid, exactly divisible volume; an invalid value skips the entry with a
diagnostic. Each half must meet the broker's minimum lot size. The two
risk-sized volumes may differ because their stop distances differ. Estimated
combined margin and existing plus new directional exposure are checked.

`InpATRPeriod`, `InpStopBufferPoints` and `InpTrailingATR` are optimizable inputs;
the ATR timeframe is always M15 and the 2R/50% rule is fixed. `InpMagic`
identifies managed positions. `InpDeviationPoints` is in symbol points, not
pips. `InpMaxSpreadPoints = 0` disables the optional entry spread filter.
Sizing excludes commissions, swap and gaps; actual execution and stop fills
can exceed the intended risk budget.

### EA verification in MetaTrader 5

Compile both the EA and indicator after installing the shared header. For
pure core assertions, copy `Market_Sessions_Core_Tests.mq5` and the header into
`MQL5/Scripts`, compile and run the script; the Experts tab should report
`PASS: all Market Sessions Core assertions.`

Use **Every tick based on real ticks** in Strategy Tester where available:

1. Compare EA signals against indicator arrows with identical session/timezone
   inputs. Test buys, sells, wick-only breaks, equality, overnight ranges,
   non-M15-aligned opening times and the DST dates below. Verify London/NY still
   signal after their opening time even when the EA was started before Asian open.
2. Check each entry's initial SL against the opposite opening-range boundary
   plus buffer, its own actual filled R, and that
   no scale-out happens below 2R. At 2R verify exactly half the original volume
   closes, the remaining stop reaches entry or better, and its subsequent
   ATR trail never loosens. Test both directions and changing ATR.
3. Test risk and fixed-lot modes, coarse volume steps, insufficient equity,
   odd-step fixed lots, spread limits, insufficient margin, disabled trading
   and broker stop/freeze rejection. Rejections must be visible in the log.
   With `InpEnableEA=false`, verify no new entries, pending midpoint
   cancellation and continued management of existing trades. Re-enable and
   verify disabled-period signals are not replayed.
4. On a demo hedging account, restart before and after each entry's half-close,
   including after a stop move; verify recovered R and no duplicate scale-out.
   Verify a netting account is rejected. Check independent old/new-session
   trails, midpoint expiry (specified and GTC), simultaneous signals, history
   delays, external exposure and partial fills where reproducible.
5. Optimize on a training period, then freeze settings and evaluate a separate
   holdout period with realistic costs. Do not optimize and evaluate on the same
   history. No profitability or future performance is guaranteed.

## Defaults and inputs

| Session | Open | Close |
| --- | --- | --- |
| Asian | 01:00 | 02:00 |
| London | 11:00 | 15:00 |
| NY | 13:30 | 21:00 |

Asian and London hours are **GMT+2 winter reference times**; NY hours are
**UTC winter reference times**, not the current broker clock. NY's default
13:30 represents 08:30 EST. Boxes and opening-time labels
are converted automatically to broker server time for each date.
Each session has separate opening/closing hour and minute and
transparency inputs. Transparency ranges from **0 (opaque) to 100 (invisible
fill)**; borders and labels match the block's signal color. The default is 85.
The former per-session color inputs are replaced by automatic gray/green/red colors.

Closing times are retained as session settings only: they do not limit
breakout monitoring, define the box range, end levels or close trades.
Monitoring and levels end at the **next session opening** instead.

- Show or hide session names; optionally append their opening times.
- Set border width (1–5 pixels) and history (1–30 calendar days, default 5).
- Hours must be 0–23 and minutes 0–59. Equal opening/closing times are rejected.
  A closing time before the opening time represents an overnight session.

## Timezones and automatic DST

- `InpDetectBrokerOffset` (default `false`) optionally measures
  `TimeTradeServer() - TimeGMT()` while connected and receiving recent quotes.
  When enabled, no broker configuration is needed for the live offset. This requires
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

Asian hours remain fixed in UTC (the default opening is 23:00 UTC). London
and NY inputs retain their respective local wall-clock schedules: the defaults
are London 09:00 local and New York 08:30 local openings. To customize them,
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
opening defaults become Asian 01:00, London 10:00, NY 14:30.
In winter on that SAST (UTC+2, no DST) broker they are Asian 01:00,
London 11:00, NY 15:30.
With a GMT+2/+3 **European-rule** broker, when both regions are in DST they
become Asian 02:00, London 11:00, NY 15:30. In the weeks
when only the US is in DST, NY opens at 14:30 on that broker. History is
converted per date, never using today's DST state for all past boxes.

NY inputs previously used GMT+2 winter references. The corrected conversion
shifts existing NY inputs two hours later; to preserve a custom NY local
schedule, subtract two hours from its old opening and closing inputs.

## Behavior

Ranges use the **first full M15 candle opening at or after the converted
session opening**, independent of chart timeframe. At 11:00 use 11:00–11:15;
at a custom 11:07 opening use 11:15–11:30. Nothing is drawn until that candle
closes and its high/low are available; missing or zero-range candles are skipped.
The range is then fixed: subsequent candles never expand it.

The box starts at the scheduled session opening and remains **gray** while
extending to quote time. Subsequent **completed M5 closes** are checked in
order: strictly above the opening high confirms **green** (buy), strictly
below its low confirms **red** (sell). Wicks and boundary equality do not
signal. Confirmation freezes the box's right edge at the M5 candle's close.
The first signal is locked even after price reversals.

The high, **50% midpoint** and low lines extend to the next chronological
Asian/London/NY opening, not the box's frozen edge. They share its signal color;
the midpoint is dotted. Unconfirmed boxes end at that next opening. No M5
confirmation at or after that boundary is accepted. Each next opening uses
its own regional and broker DST; boundaries are scheduled calendar openings,
even on weekends. An orange arrow marks the confirming M5 candle.
Historical ranges and levels remain until outside the configured history.

The top-right corner shows the current **RSI(14, close)** of H1, M15 and M5:
`H1 RSI: XX.XX | M15 RSI: XX.XX | M5 RSI: XX.XX`, regardless of the chart
timeframe. Values include the forming candle and refresh on **every tick**,
not only on candle closes; `--` is shown while a timeframe's history is still loading.

The indicator refreshes every 60 seconds and on each new M5/chart bar, and
repositions fills when the chart is scrolled, zoomed, or resized. M15 history
may need to download before boxes appear; M5 history may also need to download
before confirmation. The timer retries automatically.
Ranges are limited to the candle history supplied by your broker. Between
quotes, the server timestamp remains the last known quote time.

Real transparency is rendered with MT5's standard ARGB canvas, with native
chart objects for borders and labels. Overlapping custom sessions are painted
in chronological order, with Asian/London/NY order for the same opening day;
the last fill takes precedence in overlapping pixels. Multiple indicator
instances use separate object names. Removing or reconfiguring an instance
cleans up only its own canvas, borders, levels, labels, confirmation arrows, RSI label,
and timezone label, including after partial initialization failures.

## Manual verification (MetaTrader 5)

### NY debug logging

The **Experts** tab contains `NY DEBUG:` messages on every `UpdateSessions()`
call and every NY opening conversion, including reference dates that
are later skipped for rendering. Each conversion logs the dated input,
UTC after the GMT+2 step (no subtraction for NY), US DST status, the
0/3600-second DST subtraction, UTC before the broker offset, the offset in
minutes/seconds, and final server time.

`Expected (ref - US DST + broker)` checks the arithmetic using the reported
DST state and broker offset; it does not independently verify their correctness.
`Expected SAST (fixed UTC+2)` is a separate comparison, not an assumption about
the broker. For a summer 13:30 reference, expect UTC 12:30 and SAST 14:30;
a broker offset of 180 minutes legitimately produces server time 15:30.
In winter, expect UTC 13:30 and SAST 15:30. Check openings, overnight
date rollovers, and the DST boundary dates below. Logs are unconditional and
can be verbose across the configured history window; calculations are unchanged.

Core assertions are provided in the MQL5 test script. Compilation and visual
verification require MetaEditor/MT5.

1. Compile with F7 and check for errors/warnings, then attach to an M1 chart
   with available history. Enable automatic detection and compare the
   chart's broker UTC offset with server time minus UTC. On a fresh installation,
   check that DST is reported as unverified, rather than a guessed Europe rule.
2. Compare each box's high/low with the first completed M15 candle at/after
   the converted opening. Later price spikes must not expand its range.
3. Switch to M5/H1: ranges and converted NY opening times should stay the same.
4. Verify no box before the opening candle closes. Gray boxes extend with
   quote time; on M5 confirmation their right edge freezes, not their lines.
5. Try transparency 0/85/100, toggle labels/time labels, and zoom, scroll,
   and resize. Borders should remain anchored to the session times and range.
6. Set an opening near midnight and inspect both dates. Verify no boxes for
   missing opening candles and that NY levels end at the next Asian opening.
7. Attach two instances, then remove one: the other instance and unrelated
   chart objects must remain. Invalid times, transparency, history length,
   and border width should reject initialization with a diagnostic.
8. Observe M5 candles after the opening M15 range: a close above its high
   turns the box/levels green, below its low red, on every chart timeframe.
9. Check wick-only breaks, closes exactly on either boundary, and in-range
   closes: they do not signal; the first later M5 close outside the range does.
10. Set a nonaligned opening (e.g. 08:07): use the 08:15 M15 range after its
   08:30 close, then monitor M5 candles. A candle from before range completion
   or closing at/after the next session opening cannot signal.
11. After confirmation, refresh, zoom, scroll, and wait across midnight: colors
   must persist within the history window. Reattach the indicator and confirm
   historical colors match the same rule.
12. On an M5 chart, verify the small orange arrow marks exactly the candle
   whose close first left the range: up arrow under green breaks, down arrow
   over red breaks.
13. Compare the RSI label with standard RSI(14) indicators on H1, M15 and M5
   charts; values change on every tick, including mid-candle. Check that the
   broker offset and DST status occupy a separate line below the RSI without
   overlap, including at higher display scaling and after resizing the chart.
14. In the strategy tester, use a fixed GMT+2 broker (`BROKER_DST_NONE`) and
   check March 6/9/30, 2026: London opens at 11:00/11:00/10:00 and NY at
   15:30/14:30/14:30. Check October 23/26 and November 2: London opens at
   10:00/11:00/11:00 and NY at 14:30/14:30/15:30. Asian stays at 01:00.
   For NY transition boundaries on that fixed UTC+2 broker, use custom inputs:
   March 8 at 06:59/07:00 UTC winter reference must convert to 08:59/08:00;
   November 1 at 05:59/06:00 must convert to 06:59/08:00.
   With time labels enabled, verify each label matches its rectangle's opening
   timestamp in the Objects List: summer NY must show `NY 14:30` on fixed UTC+2,
   and winter NY `NY 15:30`. Edit an existing NY label's text to an incorrect
   time, then wait for the next session update: it must restore the box's time.
   Check that London/Asian names and times still match their box openings;
   disabling time labels must leave only the session names.
15. Repeat with a GMT+2 European-rule broker: March 30 should show Asian
   02:00, London 11:00, NY 15:30; March 9 still shows NY 14:30.
   With a US-rule broker on March 9, expect Asian 02:00, London 12:00,
   NY 15:30. Also check a fixed UTC+3 broker: winter openings are Asian
   02:00, London 12:00, NY 16:30; summer openings are 02:00, 11:00, 15:30.
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
