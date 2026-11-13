# Market-Sessions-Indicator
MQL5 opening-M15 breakout EA with built-in session boxes, per-session M5/M15
confirmation, high/midpoint/low levels and hedging-account trade management.

## Installation

1. In MetaTrader 5, select **File → Open Data Folder**.
2. Copy `Market_Sessions_EA.mq5`, `Market_Sessions_Core.mqh` and
   `Market_Sessions_EA_Visuals.mqh` together into `MQL5/Experts`.
3. Open `Market_Sessions_EA.mq5` in MetaEditor and compile with **F7**. The included
   `Canvas/Canvas.mqh` is part of MT5's standard library; no downloads are needed.
4. Refresh **Navigator → Expert Advisors** and attach **Market_Sessions_EA**.
   Configure times, broker timezone and entry timeframes once, in EA Inputs.
   No separate boxes indicator or indicator compilation is required.

## Expert Advisor

`Market_Sessions_EA_Gold_Buffer3_2R.set` is the gold stop-grid research
recommendation: 3.000 extra stop buffer, 2R half-close, BE at +1R,
ATR(14) x2 trailing from +2R, Asian M5, London M15, NY/midpoints/reversals
off, no box-height filter, fixed 0.04 lots. Load it in EA 1.11's
**Inputs -> Load**, then verify every input before applying. It enables new
entries and assumes broker UTC+2 standard / Europe DST; change that timezone
to your actual broker policy if different. Save existing inputs first.
The approximate in-sample gold replay gave +$2,189.87, PF 1.68 and 15.9%
equity drawdown from $1,000. This is not a guaranteed optimal/live-safe preset,
does not match PainX specifications, and does not change EA defaults.

As of **EA 1.10**, boxes are compiled directly into `Market_Sessions_EA.ex5`.
`Market_Sessions_EA_Visuals.mqh` is a compile-time implementation header, not a
separately installed program. Drawing reads the EA's session ranges and selected
confirmation timeframe and uses the same breakout reader as trading. There is
no second timezone, schedule or timeframe configuration to maintain.
With `InpShowSessionBoxes=true` (default), all three sessions are drawn,
even if their trading entry switches are off. `InpBoxTransparency` defaults to
85 (range 0-100). Boxes, levels, arrows, RSI and timezone labels remain visible
when `InpEnableEA=false`. Drawing is skipped in nonvisual backtests.

The EA no longer loads `Market_Sessions_Boxes.ex5` through `iCustom`. On startup
it removes legacy boxes indicators with the standard `Market Sessions Boxes`
or old `MSB EA ...` short name from its chart, logging each removal; other
indicators such as moving averages are untouched. A custom-named legacy copy
should be removed manually. Do not attach a standalone boxes indicator to this
EA's chart. Removing/reconfiguring the EA cleans up only its own drawing objects
and canvas. Set `InpShowSessionBoxes=false` only to deliberately hide its visuals.

Save your EA inputs before upgrading and verify them afterward. Reattaching,
recompiling or changing inputs does not replay earlier breakout entries.
Confirm **EA 1.11**, the selected session timeframes and management R in the chart's status labels,
and the initialization message in Experts. Box colors/arrows show confirmed
breakouts, including historical or entry-disabled sessions; they do not prove
that a trade was filled. A box appears only after the opening M15 closes and
changes color only after a selected M5/M15 close strictly outside its range.
Run in Strategy Tester and on a demo account before enabling live trading.

### Enable or disable EA entries

`InpEnableEA` defaults to **true**. Set it to **false** to block new market
and midpoint entries and cancel this EA's unfilled midpoint orders on the
next tick/timer event. Cancellation requires connectivity and algorithmic
trading permission; rejected cancellations are logged and retried.
Existing filled positions continue their independent selected-R half exits, break-even
and ATR trailing for safety, even while entries are disabled.
The standalone `Market_Sessions_Boxes.mq5` source is retained for legacy
indicator-only use with no EA management. It is not part of the EA installation
and must not be used to configure this EA's boxes.

### Sync the MQL5 source locally

```sh
git clone --branch feat/opening-range-hedging-ea https://github.com/Mo-Ice-101/Market-Sessions-Indicator.git
```

For an existing checkout on this branch, use `git pull --ff-only`.
Copy `Market_Sessions_EA.mq5`, `Market_Sessions_Core.mqh` and
`Market_Sessions_EA_Visuals.mqh` together into `MQL5/Experts`. Recopy after pulling
updates, then compile **only the EA** in MetaEditor with F7. Only the resulting
EA EX5 is needed at runtime. Git pull alone does not update the terminal folders.

### Entry and management

- Asian, London and NY can be enabled independently (`InpTradeNY` defaults to
  `false`). Each session also has a midpoint toggle (`InpAsianMidpoint`,
  `InpLondonMidpoint`, `InpNYMidpoint`, all default `false`); when off, only
  the high-risk breakout entry is taken for that session. The broker DST
  default is `BROKER_DST_EUROPE` (UTC+2 winter / UTC+3 summer). Schedules and
  reference timezones match the indicator. The EA requires an **explicit broker
  standard UTC offset and DST rule** in both live trading and backtesting;
  it does not learn offsets from the live clock. Built-in visuals use these same
  inputs automatically. Broker server location does not establish its timezone.
- Each session has a **Break Entry TF** dropdown: `InpAsianBreakEntryTF`,
  `InpLondonBreakEntryTF` and `InpNYBreakEntryTF`. Choose **M5** or **M15**;
  all default to **M5**. To use the compared mixed configuration, choose Asian
  M5 and London M15 in EA Inputs. NY remains disabled unless `InpTradeNY` is
  explicitly enabled; selecting a NY timeframe never enables NY trading.
  The opening range stays M15, and break-even, ATR, midpoint and optional
  reversal management are unchanged. Built-in box colors/arrows use the
  same per-session selections. Recopy both headers and recompile the EA after
  updating. Existing presets without these fields use
  the M5 defaults on a fresh attachment; verify selections after loading inputs.
- After the first complete M15 candle at/after a session opening, the first
  subsequent selected M5/M15 close strictly above/below that candle's range confirms a
  buy/sell. Wicks and boundary equality do not signal. RSI is not a filter.
- Each opening range can create one **high-risk market entry** and one
  **medium-risk entry when price retraces to its 50% midpoint**, in the same
  direction, only while the first position is still open in price drawdown.
  Buy triggers require ask at/below midpoint and bid below the first entry;
  sell triggers require bid at/above midpoint and ask above the first entry.
  A market request is used instead of a resting limit so eligibility can be
  checked before execution. Fill price can differ from midpoint due to gaps
  or slippage. Rejected second-entry requests are consumed until restart.
  Broker history prevents another second entry after a fill.
  "Medium risk" describes entry style, not lower sizing.
- **15M reversal strategy** (`InpEnableM15Reversal`, default `false`) optionally
  permits one opposite market entry after the first breakout position fully
  closes, including after profit or loss. A completed M15 close must be strictly
  beyond the opposite opening-range boundary, after the first position's exit
  and before the next scheduled session opens. Initial entries use the selected
  per-session M5/M15 timeframe.
  This option intentionally overrides the profit lock for the reversal only.
  If a midpoint entry has already filled, no reversal is allowed (maximum two
  entries per opening range). Reversals never create midpoint entries and use
  the same sizing, range stop, +1R break-even, selected-R half-close and ATR trailing.
  Filled reversal entries are recovered from broker history after restart;
  historical signals are not replayed. A rejected reversal attempt is consumed
  for the current run. Disabling the option blocks new reversals but leaves
  existing positions managed.
- A **hedging account is required**. Earlier sessions' EA positions do not
  block new opening-range pairs: every entry keeps its own original R, selected-R exit
  and ATR trail across all later sessions. Manual/other-EA exposure on the
  symbol and unresolved immediate market requests block new pairs.
  Simultaneous signals use reference-date order, then Asian/London/NY order.
- **Taking profit ends new entries for that session** (except an explicitly
  enabled 15M reversal), including a profitable
  selected-R partial exit or any profitable stop/manual exit. Profit means an exit deal
  with positive `DEAL_PROFIT` before fees. Broker history recovers this lock
  after restart. Already-filled positions keep their own exit management.
  If the first trade closes without profit, its midpoint trigger also ends.
  There are at most two independently managed entry positions per session.
- Unfilled midpoint triggers end at the next scheduled session opening,
  including disabled sessions and calendar weekends. No broker pending order
  is created. Running/connected terminals are required to trigger entries.
  Legacy midpoint limits from earlier versions are cancelled immediately
  on timer/tick updates; failed cancellations are logged and retried.
  Session boundaries never close filled trades or reset their trailing stops.
- `InpDaysToMonitor` defaults to the indicator's five-calendar-day horizon.
  Older sessions expire.   Only fresh confirmations from the selected timeframe
  are eligible, during the first M5 interval following that close:
  starting/restarting the EA never enters historical
  signals. Missing history is retried within the current M5 candle; signals
  missed before history arrives are not traded late. The first M5 candle
  closing after startup can signal.
- Both entries use initial SL **1.000 price units beyond the opposite M15
  range boundary**: below its low for buys, above its high for sells.
  `InpStopBufferPrice` is user-adjustable and defaults to `1.0`. For example,
  range low 2700.000 gives a buy SL of 2699.000; range high 2710.000 gives a
  sell SL of 2711.000. This is a buffer beyond the range, not a fixed distance
  from entry or an ATR initial stop. Prices round outward to tradable ticks.
  Version 1.07 replaces `InpStopBufferPoints` with a price-unit input: migrate
  old presets using `price buffer = old points * symbol point size`. On the
  3-digit gold symbol, old 10 points = 0.010 and new 1.000 = 1000 points.
  Reload the updated preset and check this input after upgrading.
  Wider buffers increase initial risk at fixed lots and also enlarge 1R/2R.
  Broker stop-distance violations reject the pair rather than widen the stop.
- **R** is actual filled entry price minus the original protective stop distance
  (the reverse for sells). By default, a completed **M1 close at +1R** moves
  the stop to entry, subject to broker restrictions and current executable
  price. Sell confirmation adds the completed candle's spread to its bid close.
  `InpBreakEvenR` adjusts this threshold; `0` disables early break-even.
  **EA 1.11:** `InpScaleOutRR` selects **1R, 2R or 3R** for closing
  **50% of the original filled volume**, default **2R** (existing behavior).
  Selecting **1R** waits for a completed M1 close at +1R (sell close includes
  spread), like the half-at-break-even test. Selecting **2R/3R** uses live
  executable bid for buys / ask for sells, not a candle close.
  After the half-close the remaining stop is moved to entry or better.
  Early break-even remains independently controlled by `InpBreakEvenR`
  (default +1R, 0 disables early BE; it does not disable a 1R half-close).
  **ATR trailing always starts at +2R**, independently of the half-close
  selection, at **2 × the latest completed M15 ATR(14)**. At 1R half-close,
  the stop stays at entry until +2R; at 3R half-close, trailing starts on the
  full position at +2R and can stop it out before +3R is reached. There is no
  additional half-close at +2R when 1R or 3R is selected. There is no fixed final take profit.
  Trailing is checked every tick, never loosens an existing stop, and cannot
  move beyond break-even toward a loss. Break-even is price-based and does
  not include commission or swap.
- Broker history supplies original entry, initial SL and completed scale-out
  volume after restart, so moving the stop does not redefine R or repeat the
  half-close. Half-close and +2R trailing triggers are independently latched
  across retracements, rejected requests and restarts. Live markers are stored in account/magic/position-
  scoped terminal global variables and removed after closure; tester runs use
  only in-memory markers and never read/write live markers. Partial execution
  is reconciled before requesting the remaining half. Midpoint triggers
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

### Approximate Python replay

`tools/sim_ea.py` preserves the research simulator for testing additional MT5
M1 exports. It uses Python's standard library only. From the repository folder:

```sh
python tools/sim_ea.py path/to/new_M1_export.csv --balance 1000 --lots 0.04
```

Defaults match the current baseline: UTC+2 with EU DST, Asian/London enabled,
NY and midpoint entries disabled, M1-close break-even at +1R, 50% exit at 2R,
then 2x M15 ATR(14) trailing, with a 1.000 price-unit initial stop buffer.
Use `--stop-buffer-price 0.01` to reproduce the old 10-point gold baseline,
or another nonnegative price-unit buffer to compare stops. Use `--verbose`
for completed trade details.
Use `--entry-minutes 5` (default) or `--entry-minutes 15` to compare M5 versus
M15 breakout-close confirmations. The opening range remains the first M15
candle; all sizing, session and exit settings stay unchanged. Confirmation
must close strictly before the next scheduled opening, matching the EA.
Simulator options do not modify the live EA's input selections.
Per-session overrides are also supported, for example:

```sh
python tools/sim_ea.py path/to/new_M1_export.csv --asian-entry-minutes 5 --london-entry-minutes 15
```

These mirror the EA's independent dropdowns; unspecified sessions use
`--entry-minutes` (M5 by default).

#### M5 versus M15 entry comparison (2026-11-09)

Replayed `XAUUSD_i_M1_202607220724_202610302254.csv` (2026-07-22 through
2026-10-30), with a $1,000 starting balance, fixed 0.04 lots, Asian/London
enabled, NY/midpoints/reversals disabled, EU broker DST, 1.000 price-unit stop
buffer, +1R M1-close break-even, half exit at 2R and the existing ATR trail.
Only the breakout confirmation timeframe differs:

| Metric | M5 confirmation | M15 confirmation |
| --- | ---: | ---: |
| Completed trades | 145 | 145 |
| Net P&L | +$1,686.37 | +$1,340.27 |
| Final balance | $2,686.37 | $2,340.27 |
| Winning trades | 32.4% | 29.7% |
| Profit factor | 1.64 | 1.43 |
| Maximum mark-to-market drawdown | 17.7% | 20.1% |
| Asian net P&L | +$267.62 | -$153.80 |
| London net P&L | +$1,418.75 | +$1,494.07 |

M5 earned $346.10 more overall in this sample, with lower drawdown. M15 earned
$75.32 more in London but $421.42 less in Asian. This is a historical
comparison, not evidence that either setting will outperform on a live account.
The history is the demo-symbol export, not the real-account `XAUUSD_r` feed.
Existing preset selection used this period, so it is not an independent
out-of-sample validation. Replay includes exported spread but excludes
commissions, swaps, margin/stop-outs and actual broker execution restrictions;
M1 OHLC cannot resolve intraminute stop/target order. Do not equate these
balances to executable real-account returns.

Reproduce each column with the same input export:

```sh
python tools/sim_ea.py path/to/XAUUSD_i_M1_202607220724_202610302254.csv --entry-minutes 5 --balance 1000 --lots 0.04
python tools/sim_ea.py path/to/XAUUSD_i_M1_202607220724_202610302254.csv --entry-minutes 15 --balance 1000 --lots 0.04
```

Clear research environment overrides (such as `SKIP`, `NOMID`, `REVERSAL`,
`NY_SWEEP`, `HALF_AT_BE`, `BE_R`, `FIXRR` or `SCALE_FRACTION`) before reproducing.

#### PainX 999 R-factor comparison (2026-11-10)

Replayed `PainX 999_M1_202609010810_202611101438.csv` from the repository's
`main` branch, September 1 08:10 through November 10 14:38 (broker timestamps).
The user confirmed UTC+2 all year (`--broker-dst none`). Session reference rules
are unchanged: Asian M5, London M15, NY disabled, including weekend bars present
in this synthetic feed. No height filter; opening M15 range, 3.000 stop buffer,
BE at +1R M1 close and ATR(14) x2 trailing armed at +2R. Midpoints/reversals off.

User-provided MT5 specification: two digits (point 0.01), linear USD CFD with
contract size 1, minimum volume 0.10, volume step 0.01, stops level 191 points
(1.91 price units), fixed margin display $70/lot. Used 0.20 lots, permitting
a valid 0.10 half-close; gold's 0.04 lots is invalid here. Exported spread
96 points becomes 0.96 price units, not 0.096. Tick size/value show rounded
zero in the screenshot, so true tick rounding is not verified. Profit uses
linear USD price difference x volume x contract size, not zero tick value.

| Half-close R | Trades | Net | Final balance | PF | Win rate | Max equity DD | Positions half-closed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 141 | -$157.26 | $842.74 | 0.85 | 47.5% | 28.5% | 67 |
| 2 | 141 | -$205.62 | $794.38 | 0.80 | 23.4% | 33.3% | 33 |
| 3 | 141 | -$210.99 | $789.01 | 0.80 | 22.7% | 34.1% | 17 |
| 4 | 141 | -$190.08 | $809.92 | 0.82 | 22.7% | 33.2% | 10 |
| 5 | 141 | -$208.36 | $791.64 | 0.80 | 22.7% | 35.1% | 3 |
| 6 | 141 | -$203.25 | $796.75 | 0.80 | 22.7% | 34.7% | 2 |
| 7 | 141 | -$194.97 | $805.03 | 0.81 | 22.7% | 34.2% | 2 |
| 8 | 141 | -$186.69 | $813.31 | 0.82 | 22.7% | 33.8% | 2 |
| 9 | 141 | -$178.40 | $821.60 | 0.83 | 22.7% | 33.5% | 2 |
| 10 | 141 | -$178.07 | $821.93 | 0.83 | 22.7% | 33.5% | 1 |

| Half-close R | September net | October net | November 1-10 net |
| --- | ---: | ---: | ---: |
| 1 | -$101.48 | -$7.21 | -$48.57 |
| 2 | -$123.12 | -$51.50 | -$31.00 |
| 3 | -$88.07 | -$71.76 | -$51.16 |
| 4 | -$68.21 | -$65.96 | -$55.90 |
| 5 | -$80.83 | -$74.59 | -$52.94 |
| 6 | -$84.01 | -$69.27 | -$49.98 |
| 7 | -$84.01 | -$63.94 | -$47.02 |
| 8 | -$84.01 | -$58.62 | -$44.06 |
| 9 | -$84.01 | -$53.30 | -$41.10 |
| 10 | -$84.01 | -$55.92 | -$38.14 |

Every setting lost money before costs; 1R is least negative, not profitable.
Trades: 70 Asian / 71 London, no stop-distance skips or forced end closures.
At 1R, Asian net -$142.90 and London -$14.36. Higher R does not delay the
independent +2R ATR trail: most positions exit before their high-R half-close.
This tests half-close targets, not a delayed-trailing or slow-swing strategy.
No live EA changes were made; the EA dropdown still supports only 1R/2R/3R.

The replay checks configured minimum stop distance, but not actual broker
acceptance, true tick rounding, freeze levels, slippage, commissions, swaps or
margin/stop-outs. The specification shows -$5/lot swaps and Friday triple
swap; these are excluded (rollover timestamps and broker charging behavior
were not confirmed). M1 OHLC does not resolve spike/stop execution ordering,
particularly important for synthetic jumps. Results are not a live forecast.
Monthly attribution uses final exit date including partial P&L. Initial
balance $1,000, no sizing compounding. The following reproduces 10R:

```sh
python tools/sim_ea.py "path/to/PainX 999_M1_202609010810_202611101438.csv" --broker-dst none --balance 1000 --lots 0.20 --point 0.01 --contract-size 1 --min-lot 0.10 --lot-step 0.01 --min-stop-distance 1.91 --stop-buffer-price 3 --asian-entry-minutes 5 --london-entry-minutes 15 --scale-out-r 10
```

Clear research environment overrides first; NY/midpoints remain off by default.
For 1R replace `--scale-out-r 10` with `--half-at-breakeven`; other tested
targets use `--scale-out-r` with an integer from 2 through 10.

#### Opening M15 box-height filter research (2026-11-10)

`--min-box-height` (inclusive, default 0) and `--max-box-height` (exclusive,
default no maximum) filter opening M15 high minus low in price units, not
points or entry-to-stop risk. They apply before confirmation/trade simulation;
session boundaries still consider all scheduled sessions. Neither flag changes
the live EA. Invalid, nonfinite or reversed bounds are rejected.

The same July 22-October 30 demo export, Asian M5 / London M15 / NY off,
$1,000 start and fixed 0.04 lots was tested with a 3.000 stop buffer,
BE at +1R and ATR trailing from +2R. Midpoints/reversals remain off.

| Height filter | Trades | Net, half at 1R | Net, half at 2R | Net, half at 3R |
| --- | ---: | ---: | ---: | ---: |
| No filter | 145 | +$1,738.87 | +$2,189.87 | +$2,202.48 |
| [0,5) | 47 | -$140.42 | -$128.90 | -$216.23 |
| [5,10) | 78 | +$1,507.19 | +$1,872.71 | +$2,012.50 |
| [10,15) | 15 | +$113.40 | +$133.96 | +$115.12 |
| [15,20) | 4 | +$24.24 | +$1.18 | -$10.04 |
| [20,30) | 0 | $0.00 | $0.00 | $0.00 |
| 30+ | 1 | +$234.46 | +$310.92 | +$301.12 |
| Below 10 | 125 | +$1,366.77 | +$1,743.81 | +$1,796.27 |
| Below 15 | 140 | +$1,480.17 | +$1,877.77 | +$1,911.40 |
| Below 20 / below 30 | 144 | +$1,504.41 | +$1,878.95 | +$1,901.36 |
| At least 5 | 98 | +$1,879.29 | +$2,318.77 | +$2,418.70 |
| At least 10 | 20 | +$372.10 | +$446.06 | +$406.21 |
| At least 15 | 5 | +$258.70 | +$312.10 | +$291.08 |
| At least 20 | 1 | +$234.46 | +$310.92 | +$301.12 |

Below 5 is identical to [0,5). No trades occur in [20,30), so below 20 and
below 30 are identical; at least 20 and at least 30 are identical.
The best net result among these tested filters is at least 5 / half at 3R:
98 trades, +$2,418.70, PF 1.99, win rate 38.8%, max equity drawdown 15.3%.
The same filter at 2R gives PF 1.95, win rate 38.8%, drawdown 15.7%;
at 1R PF 1.77, win rate 55.1%, drawdown 12.1%.
The [5,10) band at 3R has PF 2.20, win rate 41.0%, drawdown 17.0%.

These are shared filters across both sessions, not independently optimized
session filters. Repeated selection on this already-used period is in-sample
optimization; high PF on one or five trades is not reliable. A single 30+
trade contributes materially to total profit. Validate on fresh history before
choosing a live filter. All approximate OHLC/execution and omitted-cost
limitations above remain; fixed lots mean different box heights imply different
cash risk. No live defaults or EA filters were changed.

```sh
python tools/sim_ea.py path/to/export.csv --asian-entry-minutes 5 --london-entry-minutes 15 --stop-buffer-price 3 --min-box-height 5 --scale-out-r 3
python tools/sim_ea.py path/to/export.csv --asian-entry-minutes 5 --london-entry-minutes 15 --stop-buffer-price 3 --min-box-height 5 --max-box-height 10 --half-at-breakeven
```

#### Half-close at break-even, trail at 2R: comparison details

For the EA's 3R half-close variant, use `--scale-out-r 3` instead of
`--half-at-breakeven`. Break-even remains at the +1R M1 close; ATR trailing
starts on the full position at +2R, before the +3R half-close. Trailing can
therefore close a position before it reaches its half-close target.
The same Asian M5 / London M15 / NY-off replay produced 145 trades,
net +$1,862.03, final $2,862.03, PF 1.71, win rate 31.0%, maximum equity
drawdown 16.7%, and 45 winners / 68 losers / 32 flat trades. Asian net was
+$251.49 and London net +$1,610.53. Monthly net: July +$255.96 (partial),
August +$534.11, September +$571.65, October +$500.30.
This is $100.34 more than the default 2R half-close in the already-used
sample, not independent evidence of better live performance.

Research-only `--half-at-breakeven` closes half the original volume at the
executable completed M1 close that first reaches +1R and moves the remaining
stop to entry. ATR trailing stays off until executable price first reaches
+2R, then remains armed through retracements. There is no second half-close at
2R. R always uses the original filled entry and initial stop. This option
does not change the EA. It requires `BE_R=1` (default) and rejects conflicting
`HALF_AT_BE`, `FIXRR` or `SCALE_FRACTION` research overrides.

On the same July 22-October 30 export, fixed 0.04 lots, $1,000 start,
Asian M5, London M15, NY/midpoints/reversals off, and the same stop/DST settings:

| Metric | Current: half at 2R | Research: half at BE, trail at 2R |
| --- | ---: | ---: |
| Trades | 145 | 145 |
| Net P&L | +$1,761.69 | +$1,573.41 |
| Final balance | $2,761.69 | $2,573.41 |
| Winners / losers / flat | 45 / 68 / 32 | 77 / 68 / 0 |
| Win rate | 31.0% | 53.1% |
| Profit factor | 1.67 | 1.60 |
| Maximum mark-to-market drawdown | 17.7% | 14.8% |
| Asian net | +$267.62 | +$245.60 |
| London net | +$1,494.07 | +$1,327.81 |
| July net (partial month) | +$229.11 | +$303.75 |
| August net | +$628.09 | +$606.15 |
| September net | +$512.59 | +$355.89 |
| October net | +$391.89 | +$307.61 |

The higher win rate mostly converts previously flat positions into partial
winners; losing trades remain 68. Earlier realization reduces the sample's
drawdown but also net profit by $188.28. This is not new/out-of-sample evidence.
The same OHLC, spread, execution and omitted-cost limitations above apply.
The new half-close assumes execution at the triggering completed M1 close;
live execution would be on a subsequent tick and could differ. No broker
stop-modification or partial-close rejections are simulated.

```sh
python tools/sim_ea.py path/to/XAUUSD_i_M1_202607220724_202610302254.csv --asian-entry-minutes 5 --london-entry-minutes 15 --balance 1000 --lots 0.04 --half-at-breakeven
```
The input is an MT5 tab-separated M1 export with spread in points.
Instrument assumptions are 3 digits, 100 oz/lot and 0.01 minimum/step.

This is an approximate bar replay, not native EA execution: stops are processed
before targets within an M1 bar and trailing updates at M1 closes. It excludes
commissions, swaps, slippage, margin/stop-outs and broker restrictions. Validate
results in MT5 with real ticks. Research switches retained as environment
variables include `SKIP`, `NOMID`, `BE_R`, `SCALE_FRACTION`, `REVERSAL`, `UNLOCK`,
`REV_MIN`, `NY_SWEEP`, `HALF_AT_BE` and `FIXRR`; unset them for the baseline.

### Sizing and inputs

`Market_Sessions_EA_best.set` holds the recommended preset (EU DST, NY off,
midpoint entries off, fixed 0.04 lots). Load it from the EA/tester **Inputs**
tab via **Load**. It comes from an approximate M1 simulation, not an MT5 test.

Choose `InpSizing = SIZE_EQUITY_PERCENT` or `SIZE_FIXED_LOTS`.
The default is fixed **0.04 lots** (must split into two valid 50% halves);
percentage sizing defaults to **0.5% of current equity**. Both are user-adjustable and apply **separately to each
entry**, not split between them. Combined intended risk can reach twice the
selected percentage (or twice the selected lots), plus existing sessions'
remaining exposure. Each risk budget uses equity at its entry request time.
Percentage sizing uses
`OrderCalcProfit` in account currency and includes the configured adverse
deviation allowance for both market requests,
then rounds **down** to a volume divisible into two valid
equal halves. It never rounds up to meet minimum lots. Fixed lots must already
be a valid, exactly divisible volume; an invalid value skips the entry with a
diagnostic. Each half must meet the broker's minimum lot size. The two
risk-sized volumes may differ because their stop distances differ. Estimated
combined margin and existing plus new directional exposure are checked.

`InpATRPeriod`, `InpStopBufferPrice` and `InpTrailingATR` are optimizable inputs;
the ATR timeframe is always M15, trailing starts at 2R, and half-close R is
selected with `InpScaleOutRR` (1R/2R/3R, default 2R). `InpMagic`
identifies managed positions. `InpDeviationPoints` is in symbol points, not
pips. `InpMaxSpreadPoints = 0` disables the optional entry spread filter.
Sizing excludes commissions, swap and gaps; actual execution and stop fills
can exceed the intended risk budget.

### Diagnosing missed entries

`InpDebugSignals` defaults to `true` and prints messages prefixed
`Market Sessions EA [debug]` in MT5's **Toolbox > Experts** tab; in Strategy
Tester use its **Journal** tab. Turn it off to reduce logging. On startup the
EA records the enabled sessions, broker-time settings, spread/deviation limits
and broker volume, stop, freeze and filling specifications. During enabled
sessions it records the M15 range, each checked M5 close that does not break
the range, historical signals ignored after startup, entry quote/stop and
broker minimum stop distance, sizing, margin and broker response. Existing
warnings and rejection codes remain visible even when debug is disabled.

Logs are produced only while the EA is running and receiving ticks; they cannot
explain a prior missed trade if the relevant logs were not recorded. Check the
EA was attached and Algo Trading was enabled, then provide the Experts/Journal
messages around the session opening and confirmation in broker server time.
NY is disabled by the supplied preset. The next session opening, even if that
session is disabled, ends monitoring of the preceding range.

The EA respects broker minimum/step/maximum and directional volume limits,
supported FOK/IOC filling modes and stop distances. Fixed lots must be valid
and split into two valid 50% halves; percentage sizing rounds down, never up.
If constraints fail, the EA skips rather than widening the stop or increasing
volume/risk. The order is submitted once per signal; it does not retry rejected
orders or promise a better fill. Broker rejection codes and descriptions are
logged; stop/freeze constraints can change.

### EA verification in MetaTrader 5

Compile the EA after installing both EA headers; no indicator is needed. For
pure core assertions, copy `Market_Sessions_Core_Tests.mq5` and the header into
`MQL5/Scripts`, compile and run the script; the Experts tab should report
`PASS: all Market Sessions Core assertions.`

Use **Every tick based on real ticks** in Strategy Tester where available:

1. Compare EA signals against its built-in arrows and selected timeframe.
   Test buys, sells, wick-only breaks, equality, overnight ranges,
   non-M15-aligned opening times and the DST dates below. Verify London/NY still
   signal after their opening time even when the EA was started before Asian open.
2. Check each entry's initial SL against the opposite opening-range boundary
   plus buffer, its own actual filled R, and that
   no scale-out happens before the selected trigger. Test each 1R/2R/3R
   selection: 1R must wait for an M1 close; 2R/3R use executable price.
   Verify exactly half closes once, including partial fills and restart.
   Verify BE at +1R, no ATR trail before +2R, and trailing starts at +2R
   even when the 3R half-close has not happened. Check persistent triggers
   after a restart/retracement, both directions, and changing ATR.
3. Test risk and fixed-lot modes, coarse volume steps, insufficient equity,
   odd-step fixed lots, spread limits, insufficient margin, disabled trading
   and broker stop/freeze rejection. Rejections must be visible in the log.
   With `InpEnableEA=false`, verify no new entries, pending midpoint
   cancellation and continued management of existing trades. Re-enable and
   verify disabled-period signals are not replayed.
   Attach the EA alone with `InpShowSessionBoxes=true`: verify historical and
   live boxes, matching timezone/inputs, no boxes before the opening M15 closes,
   and visible levels in visual testing. Verify missing compiled indicator
   errors, disabled-entry visuals, and that EA removal leaves manually attached
   indicators intact. Nonvisual testing should not load drawing resources.
4. On a demo hedging account, restart before and after each entry's half-close,
   including after a stop move; verify recovered R and no duplicate scale-out.
   Verify a netting account is rejected. Check independent old/new-session
   trails, midpoint-trigger expiry, simultaneous signals, history
   delays, external exposure and partial fills where reproducible.
   Reproduce the reported sequence: first sell enters, takes 2R profit, exits
   its remainder, then price reaches midpoint. No second entry may occur.
   Also test a midpoint reached before any profit while the first is in
   drawdown (second permitted), first closing at loss/break-even, profit in
   either already-filled leg, restart after profit, and later sessions
   remaining independently eligible.
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
  (default `BROKER_DST_EUROPE`), and `InpBrokerDSTMinutes` (default 60, range 1–120).
  The strategy tester always uses these inputs because its `TimeGMT()` equals
  simulated server time; it neither reads nor writes live observations.
  Its default is UTC+2 with European DST (UTC+3 in summer);
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
