# Session handover

Saved 2026-11-08 at the user's request. This is a condensed handover, not a
verbatim transcript. This branch is based on `feat/opening-range-hedging-ea`
at commit `6bf342c`; it does not merge the Gold Desk branch.

## Earlier Gold Desk discussion: found

The earlier handover is
[`gold_agent/CONVERSATION_HANDOFF.md`](https://github.com/Mo-Ice-101/Market-Sessions-Indicator/blob/feat/gold-news-agent/gold_agent/CONVERSATION_HANDOFF.md)
on `feat/gold-news-agent` (draft PR #17). Earlier in this conversation the
assistant incorrectly said it could not find the handover; it was on that
separate branch.

That document describes a local Windows Gold Desk using GDELT and official
news, MT5 gold/USD data and local Ollama, with a separate Streamlit dashboard
and prospective one-hour forecast evaluation. The Desk is **read-only**: the
previous handover explicitly says no EA trade blocking or integration has been
approved. Earlier messages in this chat discussed an EA enable/disable filter
and an on-chart reasoning dashboard; reconcile that with the later documented
read-only decision with the user before changing trading behavior.

The older handover records that the user wanted clearer session/readiness
information and validation during live market hours. Its full operational
details and caveats are in the linked document.

## Opening-range EA and stop buffer

- EA work is in `feat/opening-range-hedging-ea`, PR #16. The preset enables
  Asian and London, disables NY and midpoint entries, and uses fixed 0.04 lots.
  Early break-even is on an M1 close at +1R, 50% is closed at 2R, and the
  remainder uses M15 ATR(14) x2 trailing.
- EA v1.07 replaced `InpStopBufferPoints` with adjustable
  `InpStopBufferPrice`, default `1.0` price units beyond the opposite M15
  opening-range boundary. It is not a fixed entry-to-stop distance. On the
  user's three-digit gold symbol, 10 points is `0.01` price units and 1,000
  points is `1.0`. Old presets require conversion; see `README.md`.
- The preset and `tools/sim_ea.py` were updated to match. Manual modification
  of an open position's stop is subject to broker restrictions; EA management
  can later tighten it, and R still uses original entry and original stop.
  Changing the input does not retroactively alter an already-open stop.
- With 0.04 lots and 100 oz/lot, a 1.000 price-unit buffer alone adds about
  $4 to initial risk. Total risk also includes the entry-to-range-boundary
  distance and costs; $100 account balance does not cap fixed-lot risk.

## Gold replay results and limitations

The gold data `XAUUSD_i_M1_202607220724_202610302254.csv` is on `main`, not
on the EA feature branch. `tools/sim_ea.py` from the EA branch uses approximate
M1 replay and three-digit/100-oz gold assumptions. For comparison, all runs
started at $1,000, fixed 0.04 lots, EU broker DST, Asian/London on, NY and
midpoints off. Other settings were unchanged.

| Buffer in price units | Net profit | Profit factor | Maximum equity drawdown |
| ---: | ---: | ---: | ---: |
| 0.010 | +$1,297.20 | 1.53 | 16.4% |
| 0.100 | +$1,389.75 | 1.56 | 16.4% |
| 0.250 | +$1,383.05 | 1.55 | 19.1% |
| 0.500 | +$1,390.85 | 1.53 | 19.5% |
| 1.000 | +$1,686.37 | 1.64 | 17.7% |
| 2.000 | +$1,842.18 | 1.63 | 14.4% |
| 5.000 | +$1,044.56 | 1.26 | 29.2% |

These are in-sample comparisons, not proof of optimality or future profit.
They exclude commissions, swaps, slippage, margin/stop-outs and broker execution
restrictions, and are not MT5 real-tick tests. Wider stops change both risk
and R-based target distances. The 1.000 buffer became the default; 2.000
was **not** selected as the default. The simulator accepts
`--stop-buffer-price` for future comparisons.

## Missed Friday entry and broker constraints

The user reported a missed Friday trade; the exact cause remains unknown.
EA v1.08 added `InpDebugSignals=true`, logging session/range checks, M5 closes,
candidate entry pricing, broker stop/volume/fill constraints, sizing, margin
and trade responses in MT5 Toolbox > Experts; Strategy Tester uses Journal.
It cannot reconstruct missing prior logs. Request the exact Experts messages
and broker-server time of the missed trade if available.

The user explicitly withdrew the request for ten retries: **do not add order
retries** without renewed agreement. The EA checks broker volume min/step/max,
directional exposure limits, stop distance and supported FOK/IOC filling; it
skips invalid entries rather than silently increasing lots/risk or widening SL.
Fixed lots must split into two valid 50% halves. Broker execution and actual
fills still require native MT5/demo verification.

## Outstanding MT5 chart issue

The user saw `initializing ... failed with code 1` when attaching the EA and
reported that it loaded after removing a second boxes indicator. The screenshot
did not show the specific Experts-tab initialization error. Another screenshot
showed the EA loaded but **no boxes visible**. The user says the boxes indicator
must be loaded separately for visuals.

The EA source intends to attach `Market_Sessions_Boxes` when
`InpShowSessionBoxes=true`, but actual cause of the missing visuals or prior
attach failure is unverified. Do not assert that auto-attachment works on the
user's installation. As a workaround, attach the boxes indicator separately
and set `InpShowSessionBoxes=false` to avoid a second EA-owned instance.
Investigate actual Experts logs, EA/indicator versions, installed `.ex5` paths,
and chart visibility before changing code. The screenshot showed broker
`UTC+03:00 | DST: None`; confirm actual broker timezone and ensure EA and
separate indicator settings match, rather than assuming this is correct.

Native MetaEditor compilation, visual rendering and live execution of these
changes were not verified in the Linux environment.

## GitHub Desktop / local workflow

The user uses GitHub Desktop. EA updates were pushed to
`feat/opening-range-hedging-ea`; the Changes tab shows uncommitted local changes,
not the already committed branch history. The user had thousands of untracked
`gold_agent/.venv` files visible locally. Do not discard them or commit them
blindly. GitHub Desktop updates the repository copy; any separate MT5 data
folder copies must be synced and recompiled.

## Separate NAS100 work

The user also has `Mo-Ice-101/NAS100_EMA_V-WAP_IndicatorEA`, PR #2. It contains
an M1-data Python backtester for a separate M3 EMA9/daily tick-volume VWAP EA,
including full-session comparisons. Do not confuse those results or symbols
with the gold opening-range EA. A later trailing-stop research run produced
exploratory results, but its final validation/publish command was interrupted;
check that repository's branch/status before assuming those changes persisted.
