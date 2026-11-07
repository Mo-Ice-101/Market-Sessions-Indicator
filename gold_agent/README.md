# Gold news and market-context agent

A standalone, read-only Python monitor for a Windows PC/VPS running MetaTrader 5.
It does not modify the session indicator, place orders, or provide guaranteed
price predictions. It runs independently; its reports are not drawn on the MT5 chart.

## Setup on Windows

### Double-click startup (Python 3.11)

Open MT5 and log into your broker, then double-click **`Start_Gold_Agent.cmd`**
in this folder. It creates the Python environment if missing, installs the MT5
connector only when its import fails, and presets gold to **`XAUUSD_i`**.
Startup and every scan use the explicit terminal
`C:\Program Files\Weltrade MT5 Demo\terminal64.exe`, avoiding automatic selection
when multiple MT5 installations are present. Keep that terminal logged in.
If it moves, update `MT5_PATH` in `launcher.py`; a missing executable stops startup.
On first run, choose your exact USD comparison symbol and its orientation.
The choices and local model name are saved in git-ignored `data/startup.json`;
remove that file to reconfigure. No broker credentials are saved.

Install Ollama from https://ollama.com/download/windows first. The launcher
starts its local server if needed and verifies it responds. If the chosen
local model is missing, it asks permission to download it (potentially several
GB); declining stops startup, rather than silently disabling AI. The default
model is `qwen2.5:7b`; choose a smaller local model if your hardware requires it.
Keep the console open for continuous monitoring; Ctrl+C stops it.
An Ollama server started by the launcher is stopped when it exits; an already
running server is left untouched. Startup logs are in `data/ollama-startup.log`.
Only one launcher can run per data folder. Do not also run a manual monitor
against the same output folder. Ollama responsiveness/model checks do not
verify inference quality; check the first report's AI status and reasoning.

### Manual setup

Install Python 3.10+ (64-bit) and MT5. Open MT5, log into your broker, and enable
the exact gold and dollar comparison symbols in Market Watch. Let M5 history load.
Run the commands below in PowerShell from the repository root:

```powershell
py -m venv gold_agent\.venv
gold_agent\.venv\Scripts\python.exe -m pip install -r gold_agent\requirements.txt
```

For free local AI interpretation, install Ollama from https://ollama.com/,
then download a model your machine can support, for example:

```powershell
ollama pull qwen2.5:7b
```

Ollama must be running on `127.0.0.1:11434`. Model downloads need network access
and disk space; inference uses local CPU/GPU/RAM. The monitor sends no evidence
to a cloud model and reads only public headlines, closing prices, and yields.
Use a trusted local Ollama installation, not a cloud-backed model.

If your broker provides a USD index, use its exact symbol:

```powershell
gold_agent\.venv\Scripts\python.exe gold_agent\agent.py --gold-symbol "XAUUSD.i" --usd-symbol "DXY" --ollama-model "qwen2.5:7b" --once
```

These symbol names are examples, not auto-detected broker names. Confirm the
index is oriented so a higher price means a stronger USD. If your broker has no
USD index, EURUSD is a less complete alternative:

```powershell
gold_agent\.venv\Scripts\python.exe gold_agent\agent.py --gold-symbol "XAUUSD.i" --usd-symbol "EURUSD" --usd-inverse --ollama-model "qwen2.5:7b"
```

`--usd-inverse` negates FX log returns because EURUSD falling implies USD
strength **relative to EUR**, not against all currencies. It must not be used
with DXY or a USD-base pair such as USDJPY. EUR-specific news can distort this
proxy. Symbol suffixes must match your broker.
For manual commands with multiple installations, also pass
`--mt5-path "C:\Program Files\Weltrade MT5 Demo\terminal64.exe"`.
Without this argument, manual mode uses MT5's automatic terminal selection.

Omit `--once` to monitor continuously. Scans run every 900 seconds **after the
previous scan finishes**, configurable with `--interval` (minimum 300).
Omit `--ollama-model` for quantitative monitoring without AI; reports explicitly
label inference disabled. Missing or invalid AI output is recorded as an error,
not replaced with a fabricated assessment.

## Evidence and output

Public inputs require no API keys:

| Source | Use | Limitations |
| --- | --- | --- |
| GDELT DOC API | Global headline discovery | At most 100 newest matches per query, indexing delays, first-seen timestamps; not exhaustive |
| Federal Reserve, ECB, BLS, BEA RSS | Official policy and economic release headlines | Feed retention varies; headlines are not full release analysis |
| FRED public DFII10 CSV download | US 10-year real Treasury yield context | Daily observations, not live yields; no FRED API key because this is a public CSV download, not the keyed API |
| Your MT5 broker | Completed gold and USD-comparison M5 bars | Windows required; broker coverage, history and licensing apply |

The agent does **not** scrape paywalls or redistribute full articles. Follow
source terms, preserve attribution, and expect throttling or source outages.
Failed feeds appear in `source_health` and the overall scan becomes `degraded`.
No recent headlines does not mean no relevant news occurred.

Default output is `gold_agent/data/` (git-ignored):

- `latest.json`: most recent complete report, replaced atomically.
- `report-<UTC timestamp>.json`: historical reports with source-linked headlines,
  quantitative context, qualitative AI reasoning and caveats.
- `state.sqlite3`: URL-based deduplication; emitted headlines have `new: true`
  only on their first report. Older retained headlines remain available as context.
- `agent.log`: source failures and scan summaries.

Console JSON gives the report path, new-headline count, market context and AI
assessment. This is a console/file alert surface, not email or Telegram delivery.
Reports and logs accumulate: archive or remove old files as appropriate. Run only
one monitor per output directory. Changing `--output` changes the deduplication
state. News freshness defaults to 24 hours (`--lookback-hours`, range 1-72).
Only the newest 30 headlines enter each report/AI prompt (`--max-headlines`, 1-100);
the report records retrieval limits and truncation.

Correlations use **log returns, not price levels**, matching consecutive M5
intervals by UTC timestamps. Forming candles and missing-bar intervals are
excluded. Windows require 36 and 288 matched return samples (normally 3 and 24
trading hours); elapsed calendar hours are also reported because gaps/weekends
can extend them. Correlations are unavailable until each window is complete.
A value <= -0.3 is labeled inverse, >= +0.3 positive, otherwise weak. Crossing
the inverse threshold between long and short windows flags weakening or
strengthening; these descriptive thresholds are not statistically validated
trading triggers. A zero-variance series has no correlation.

The recent-movement comparison uses 12 consecutive M5 returns ending at the
latest shared completed bar. Missing intervals are labeled incomplete; moves
below 0.05% in either series are labeled small. Gold and USD rising together is
reported as same-direction, not forced into the usual inverse assumption.
Bars over 15 minutes behind their expected close are stale (including closed
markets). Real-yield observations over seven calendar days old are stale.

Local AI receives the bounded evidence snapshot and must distinguish observed
co-movement from possible drivers. Output is schema-checked and article IDs must
exist in that snapshot. Missing/stale market data forces insufficient evidence
and low confidence, but schema checks cannot prove the model's reasoning is
correct. Confidence describes evidence quality, **not a calibrated probability
of profit**. Headlines are untrusted input and interpretations need human review.

This initial version does not ingest ETF flow datasets, central-bank purchase
statistics, a future economic-event calendar, consensus forecasts, intraday
real yields, or a multi-currency USD basket. It cannot calculate economic
surprises without reliable forecast data or establish which headline caused
a price movement.

## Keep it running

Keep MT5 logged in, Ollama running if used, and Windows awake. For unattended
use, create a Windows Task Scheduler task under the same Windows user as MT5:
trigger at logon, program the full path to the virtualenv's `python.exe`, pass
the full path to `agent.py` and your arguments, and set the repository as
"Start in". Do not add `--once` for the continuous monitor; configure the task
not to start a second instance. Do not put broker credentials in arguments/files.
Stop a foreground monitor with Ctrl+C.

A one-shot scan returns exit code 1 for degraded output; it still writes the
report so outages remain visible. Fatal persistence errors also return 1.
An always-on scan logs degradation and tries again on the next interval.

## Development checks

No MT5 connection or model is needed for deterministic tests:

```powershell
gold_agent\.venv\Scripts\python.exe -m unittest discover -s gold_agent -p "test_*.py"
```

On your Windows machine, run `--once`, check `latest.json` source health, verify
the selected symbol orientation, and compare the latest completed M5 timestamps
and recent returns with MT5. Confirm Ollama reports `status: ok`, then disconnect
MT5 to verify errors are visible. Linux can run the deterministic tests but
cannot validate the Windows MT5 connection.
