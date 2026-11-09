# Gold Desk conversation handoff

Saved on 2026-11-07 at the user's request so work can resume in a later session.
Last updated on 2026-11-09.
This is a condensed record of decisions and outstanding work, not a verbatim
chat transcript.

## Goal and agreed setup

Build an active gold-market news agent with a friendly local web interface,
with a path to hosting later. Correlate gold with USD strength and US real yields
without assuming the usual inverse USD/gold relationship always holds.
Use free/public sources where practical; do not promise exhaustive global news
coverage or reliable price predictions.

The agent lives alongside the existing indicator on branch
`feat/gold-news-agent`, in draft PR #17. The trading EA source and saved preset
were inspected on `feat/opening-range-hedging-ea`. Do not modify the EA's strategy
or block its trades: the Desk is currently a separate read-only monitor.

The user runs Windows with Python 3.11 and two MT5 installations. The launcher
and every market scan explicitly use:

```text
C:\Program Files\Weltrade MT5 Demo\terminal64.exe
```

Confirmed broker symbols:

```text
Gold: XAUUSD_r (updated 2026-11-09; previous demo symbol was XAUUSD_i)
USD index: initially DXYUSD; confirm the real-account symbol saved by setup
USD orientation: higher index price means stronger USD (no inversion)
```

On 2026-11-09 the user reported the real-account gold symbol is `XAUUSD_r`
and reconfirmed the same `C:\Program Files\Weltrade MT5 Demo` installation
path. The launcher preset was updated; the terminal path remains unchanged.
Live connection still needs confirmation on the user's Windows machine.

Ollama and the local `qwen2.5:7b` model are installed on the user's machine.
The model download was approximately 4.7 GB.

## Startup and interface

The user requested one file to run everything. Double-click
`gold_agent/Start_Gold_Agent.cmd`. It prepares the virtual environment and
missing dependencies, connects to the selected MT5 installation, checks/starts
local Ollama, starts the monitor and opens the Streamlit dashboard:

```text
http://127.0.0.1:8501
```

The console must remain open; Ctrl+C stops the Desk, not the EA. Updates are
obtained by Fetch/Pull origin in GitHub Desktop on `feat/gold-news-agent`, then
restarting the launcher. Local configuration and reports are git-ignored in
`gold_agent/data/`.

The dashboard refreshes its display every 30 seconds. New agent scans wait
five minutes after the previous scan finishes. Local inference allows up to
ten minutes, so predictions are not guaranteed to appear at session start or
every five minutes. Headline snapshots are limited to ten in the launcher.

## Sessions and prediction evaluation

The user confirmed the repository's EA preset/default session settings:
Asian and London trading enabled, New York trading disabled.
The Desk independently enables analysis in all three sessions, including
New York for the user's manual use. EA New York trading remains unchanged.

Analysis windows start after the opening M15 candle and end at the next
scheduled session opening:

| Session | Analysis starts | Analysis ends |
| --- | --- | --- |
| Asian | 23:15 UTC | London open, 09:00 London local time |
| London | 09:15 Europe/London | New York open, 08:30 New York local time |
| New York | 08:45 America/New_York | 23:00 UTC |

London and New York use independent IANA daylight-saving rules. Analysis
requires fresh market data. News collection continues outside analysis windows.

The user chose a one-hour outcome horizon after it was explained as:
if the screen says gold may rise, wait one hour to check whether it did.
Directional assessments are mapped from supportive to up and pressuring to
down. Mixed/insufficient assessments are not scored as directional calls.
SQLite records forecasts and their session labels; later scans compare the
baseline completed M5 gold close with the first completed M5 close at or after
one hour, within a ten-minute tolerance. Larger market gaps expire unscored.

This is prospective forward evaluation, not a historical AI backtest or a
profitability simulation. The included July–October gold M1 CSV lacks matching
archived headlines and historical AI forecasts. Do not invent historical AI
performance from that price file. Costs, slippage and EA trade rules are not
included in the displayed directional hit rate.

## Observed live behavior and fixes so far

The user successfully launched the dashboard on Windows. Their screenshots
confirmed MT5 gold/USD history retrieval, Streamlit rendering and official
Treasury real-yield fallback.

Earlier issues and implemented handling:

- Multiple MT5 installations caused a terminal-call failure. Explicit terminal
  selection was added for both startup and every scan.
- GDELT returned HTTP 429. Added an exponential cooldown starting at 30 minutes,
  respecting longer Retry-After values; official RSS continues. Cooldown state
  is process-local.
- The FRED public CSV endpoint returned HTTP 404. Added attributed official
  Treasury real-yield XML fallback; FRED may still return 404.
- Local AI timed out. Increased timeout to ten minutes and bounded headline
  input/output.
- AI returned unsupported article references. Such calls are now withheld as
  insufficient evidence, with low confidence and an explicit caveat; do not
  treat this as a validated prediction.

Public-news coverage includes GDELT and Fed, ECB, BLS and BEA RSS. There is no
exhaustive global coverage, future economic-event calendar, consensus-surprise
data, or automated trade/news-blocking integration.

## Earlier dashboard feedback

On Saturday, 2026-11-07, the user agreed to wait until the market reopens
before assessing fresh-price behavior. Last screenshots showed:

- Main card: Waiting For Analysis.
- Warning: analysis window open but fresh market prices unavailable.
- Stale historical gold/USD metrics, not live moves or predictions.
- Tiny schedule caption showing New York analysis enabled and EA entries disabled.

The user could not easily find the explanation of session timing or prediction
status on the dashboard. The full-screen screenshot confirmed poor prominence,
not a missing session caption. We explicitly acknowledged:

- Session information is buried in small text.
- "Analysis window active" means scheduled hours match, not that the market is
  open; it is misleading on weekends.
- There is no prominent next-assessment time/countdown, popup, or sound alert.
- Historical market changes are not forecasts.

The prominent schedule/countdown, scan-progress and weekend-status improvements
have **not** been implemented. Readable AI predictions were subsequently added
as described below.

## Readable AI predictions (2026-11-09)

The user explicitly wanted to read the AI's prediction and reasoning, separately
from the EA. The dashboard now prominently shows UP bias, DOWN bias, No clear
direction or Insufficient evidence, with reasons, opposing evidence and an
invalidation condition. Observed market changes are labeled as not predictions.
Evidence and AI-completion timestamps, model, article references and source
warnings are displayed.

Ollama now receives a structured JSON schema with permitted article IDs.
Unsupported references are still rejected locally. Failed news retrieval must
not be described as proof that no market-moving news exists. Added an official
Fed monetary-policy RSS fallback when the all-releases feed fails; it has
narrower coverage and is labeled accordingly.

These changes are on `feat/gold-news-agent`, implementation commit `cc26974`.
The Python suite passed 53 tests, including Streamlit AppTest. Successful live
inference with the new schema still needs confirmation on Windows.

Evaluation caveat: the one-hour baseline is the evidence's completed M5 close,
not the time inference finishes. Slow inference can consume part of that hour,
and the recorded forecast creation time currently uses scan start. Correct
availability timestamps/baselines before treating this as an actionable,
leakage-aware performance evaluation.

## EA breakout timeframes and comparison (2026-11-09)

The original initial breakout entry used an M5 candle close strictly outside
the opening M15 high/low, not M1. M1 is used for early break-even at +1R.
The opening range remains M15 regardless of the entry or chart timeframe.

At the user's request, added independent M5/M15 dropdowns:
`InpAsianBreakEntryTF`, `InpLondonBreakEntryTF`, `InpNYBreakEntryTF`.
All default to M5. Asian M5 / London M15 is now selectable; it is not the
default. New York EA trading remains disabled, and its selector cannot enable
trading. Desk New York analysis remains enabled independently.

EA, indicator, shared helpers, simulator, documentation and tests were updated.
Commit `170c8ee` was pushed to both `feat/opening-range-hedging-ea` and
`feat/backtest-entry-timeframes`. These changes are on those branches, not the
Gold Desk branch. The existing saved preset was not rewritten.

To install: pull the intended branch, copy the updated EA, indicator and shared
header to the appropriate MT5 folders, and compile both programs. Git updates
alone do not update installed EX5 files. The user previously missed changes
because GitHub Desktop still showed pending pulls. Native MT5 compilation and
visual verification remain outstanding; 10 portable tests passed.

Approximate replay on the included July 22-October 30 gold history used $1,000
starting balance, fixed 0.04 lots, Asian/London enabled, New York/midpoints/
reversals disabled, Europe broker DST and a 1.000 stop buffer:

| Entry selection | Trades | Net | Profit factor | Max drawdown |
| --- | ---: | ---: | ---: | ---: |
| Both M5 | 145 | +1686.37 | 1.64 | 17.7% |
| Both M15 | 145 | +1340.27 | 1.43 | 20.1% |
| Asian M5 / London M15 | 145 | +1761.69 | 1.67 | 17.7% |

This is an approximate price-based EA replay, not an AI backtest, live result
or out-of-sample validation. It excludes commissions, swaps and margin effects.

## Where we stopped: different boxes between brokers

The user loaded the EA at another broker and reported different session boxes
despite identical inputs and both servers being physically located in South
Africa. Screenshots showed both configured as
`Broker UTC+02:00 | DST: Europe (manual/tester)`, but their server clocks differed.
The user then confirmed simultaneous Market Watch times:

- Correctly aligned broker: 10:41.
- Incorrectly aligned broker: 08:41.

This confirms a two-hour server-clock difference, not identical timezones.
Physical server location does not establish its trading-clock UTC offset.
Applying the same manual offset to both can select different opening candles
and shift entries as well as boxes.

Advice given: if the correct broker's UTC+2 configuration is accurate, change
the incorrect broker's EA `InpBrokerUTCOffset` from `2.0` to `0.0`, without
changing the session opening inputs. At the conversation timestamp
2026-11-09 08:47 UTC, the reported clocks are consistent with UTC+2 and UTC+0.
The new broker's daylight-saving policy is still unconfirmed; do not assume
Europe DST or no DST solely from today's clocks.

The EA explicitly converts session UTC times using its configured broker
standard offset and DST rule. It passes those settings to its attached boxes
indicator and disables automatic offset detection there. Adjusting only a
standalone indicator does not correct EA scheduling.

The screenshots used M15 and M30 chart displays, but opening-range data is
explicitly M15, so display timeframe is not the cause. Broker feed OHLC and
spread differences may remain after time alignment.

No code change was made for this discrepancy. The user has not yet confirmed
applying the offset correction or matching boxes afterward.

## Next-session priorities

1. Confirm the new broker's offset correction, actual DST policy and installed
   EA/indicator versions. Compare the same UTC opening M15 candle on both feeds
   after correction; keep session reference hours unchanged.
2. Verify MT5 compilation and the per-session M5/M15 inputs on the EA branch,
   keeping New York trading disabled.
3. Validate the running Desk during actual market hours: intended MT5 terminal,
   fresh aligned gold/USD bars, news-source health, successful local AI output,
   and one-hour forecast persistence/outcome scoring.
4. Correct forecast availability timestamps/baselines before interpreting
   forward scores as actionable results.
5. Make current session, analysis readiness/blocked reason, last successful
   assessment time and scan progress prominent. Distinguish scheduled eligibility
   from a verified live market. Do not imply an exact prediction time if inference
   duration is unknown.
6. Evaluate session-specific forecasts honestly before connecting anything to
   trading. No EA integration or trade blocking has been approved.
7. Clarify the separate historical AI backtesting requirement if the user wants to
   pursue it: it needs appropriate historical evidence and leakage-aware replay,
   not merely the gold-price CSV.

Reports and logs currently accumulate without automatic retention. Headlines
have limited deduplication retention, but forecasts remain in SQLite. Hosting,
authentication, data sync, notification delivery and disk-retention controls
are not implemented.

The checks above do not establish trading usefulness, forecast calibration,
native MT5 compatibility or complete live-source reliability.
