# Gold Desk conversation handoff

Saved on 2026-11-07 at the user's request so work can resume in a later session.
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
USD index: DXYUSD
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

## Where we stopped

It was Saturday, 2026-11-07. The user agreed to wait until the market reopens
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

These interface improvements were discussed but have **not** been implemented.

## Next-session priorities

1. Validate the running Desk during actual market hours: intended MT5 terminal,
   fresh aligned gold/USD bars, news-source health, successful local AI output,
   and one-hour forecast persistence/outcome scoring.
2. Make current session, analysis readiness/blocked reason, last successful
   assessment time and scan progress prominent. Distinguish scheduled eligibility
   from a verified live market. Do not imply an exact prediction time if inference
   duration is unknown.
3. Evaluate session-specific forecasts honestly before connecting anything to
   trading. No EA integration or trade blocking has been approved.
4. Clarify the separate historical backtesting requirement if the user wants to
   pursue it: it needs appropriate historical evidence and leakage-aware replay,
   not merely the gold-price CSV.

Reports and logs currently accumulate without automatic retention. Headlines
have limited deduplication retention, but forecasts remain in SQLite. Hosting,
authentication, data sync, notification delivery and disk-retention controls
are not implemented.

The latest implementation changes passed 50 deterministic Python tests and
compilation checks. A local Streamlit HTTP health endpoint was also checked.
Those checks do not establish trading usefulness, forecast calibration or
complete live-source reliability.
