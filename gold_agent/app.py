"""Local Streamlit dashboard for current gold context and forward-tested calls."""

import json
import sqlite3
from pathlib import Path

import streamlit as st

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
REPORT = DATA / "latest.json"
DATABASE = DATA / "state.sqlite3"

st.set_page_config(page_title="Gold Desk", page_icon="◈", layout="wide")
st.markdown(
    """
    <style>
    .block-container { max-width: 1440px; padding-top: 2rem; }
    [data-testid="stMetric"] {
      background: linear-gradient(135deg, #151d2d, #202b40);
      border: 1px solid #35435d; padding: 18px; border-radius: 12px;
    }
    .hero {
      background: linear-gradient(120deg, #17243b, #26334b);
      border: 1px solid #3a4b67; padding: 24px; border-radius: 16px;
      margin: 8px 0 20px 0;
    }
    .subtle { color: #aab6cb; }
    </style>
    """,
    unsafe_allow_html=True,
)


def load_report():
    try:
        return json.loads(REPORT.read_text(encoding="utf-8")), None
    except FileNotFoundError:
        return None, "No report yet. Keep the Gold Agent running for its first scan."
    except (OSError, json.JSONDecodeError) as exc:
        return None, f"Could not read the latest report: {exc}"


def load_forecasts():
    if not DATABASE.exists():
        return [], "No forecast history yet."
    try:
        with sqlite3.connect(f"{DATABASE.as_uri()}?mode=ro", uri=True, timeout=3) as db:
            exists = db.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='forecasts'"
            ).fetchone()
            if not exists:
                return [], "Forecast logging starts with the latest agent version."
            rows = db.execute(
                """SELECT created_utc, direction, confidence, model, baseline_price,
                          target_price, actual_return_percent, correct, target_utc, outcome_status
                   FROM forecasts ORDER BY id DESC LIMIT 1000"""
            ).fetchall()
        return rows, None
    except sqlite3.Error as exc:
        return [], f"Could not read forecast history: {exc}"


def pct(value):
    return "—" if value is None else f"{value:+.3f}%"


def display_report(report):
    market = report.get("market") or {}
    ai = report.get("ai") or {}
    ai_result = ai.get("result") or {}
    status = report.get("status", "unknown").upper()
    assessment = ai_result.get("assessment", "Waiting for analysis")
    confidence = ai_result.get("confidence", "—")
    st.markdown(
        f'<div class="hero"><span class="subtle">GOLD DESK · {status}</span>'
        f'<h1 style="margin:.35rem 0">{assessment.replace("_", " ").title()}</h1>'
        f'<span class="subtle">{confidence.title()} evidence confidence · '
        f'updated {report.get("as_of_utc", "unknown")}</span></div>',
        unsafe_allow_html=True,
    )
    if ai.get("status") == "error":
        st.error(f"AI analysis failed: {ai.get('error', 'unknown error')}")
    elif ai.get("status") == "disabled":
        st.info("AI analysis is disabled.")
    if ai_result.get("summary"):
        st.write(ai_result["summary"])
    for caveat in ai_result.get("caveats", []):
        st.warning(caveat)

    gold_move = market.get("gold_return_percent")
    usd_move = market.get("usd_strength_return_percent")
    windows = market.get("windows_m5_returns", {})
    corr_short = windows.get("36", {}).get("correlation")
    corr_long = windows.get("288", {}).get("correlation")
    cols = st.columns(4)
    cols[0].metric("Gold · recent move", pct(gold_move))
    cols[1].metric("USD · recent move", pct(usd_move), market.get("usd_measure", ""))
    cols[2].metric("Gold / USD · short", "—" if corr_short is None else f"{corr_short:+.2f}")
    cols[3].metric("Relationship", market.get("relationship", "unavailable").replace("_", " ").title())
    if market.get("status") == "stale":
        st.warning("Market prices are stale. The market may be closed; this is not a live reading.")
    elif market.get("status") != "ok":
        st.error(f"Market data unavailable: {market.get('error', 'unknown error')}")
    st.caption(
        f"Gold/USD short correlation: {windows.get('36', {}).get('samples', 0)}/36 samples. "
        f"Long: {corr_long if corr_long is not None else 'waiting for history'}. "
        f"Regime: {market.get('relationship_change', 'unknown').replace('_', ' ')}. "
        "Correlations are descriptive, not causal or trading signals."
    )
    yields = report.get("real_yields") or {}
    if yields.get("status") == "error":
        st.warning(f"US real-yield context unavailable: {yields.get('error', '')}")
    else:
        st.caption(
            f"US real yield: {yields.get('yield_percent', '—')}% on "
            f"{yields.get('observation_date', '—')} ({yields.get('series', 'source unavailable')}); "
            f"daily context, not an intraday signal."
        )
    if yields.get("source_warning"):
        st.caption(yields["source_warning"])


def display_news(report):
    health = report.get("source_health", {})
    st.subheader("Source status")
    columns = st.columns(min(5, max(1, len(health))))
    for index, (source, state) in enumerate(health.items()):
        col = columns[index % len(columns)]
        if state.get("status") == "ok":
            col.success(f"{source} · {state.get('recent_items', 0)} recent")
        else:
            col.error(f"{source} · unavailable")
            if state.get("retry_after_utc"):
                col.caption("Retry after " + state["retry_after_utc"])
    news = report.get("news", [])
    st.subheader(f"Recent headlines ({len(news)})")
    if not news:
        st.info("No matching recent headlines were returned. This does not mean no relevant news occurred.")
    for item in news:
        label = f"{item.get('source', 'Source')} · {item.get('published_utc', '')}"
        with st.expander(item.get("title", "Untitled headline")):
            st.caption(label)
            st.write("Topics: " + (", ".join(item.get("topics", [])) or "not classified"))
            if item.get("timestamp_basis"):
                st.caption(item["timestamp_basis"])
            st.link_button("Open original source", item["url"])
    st.caption(report.get("coverage", {}).get("limitations", "Headlines are bounded and not exhaustive."))


def display_forecast_test(rows, error):
    st.subheader("One-hour forecast evaluation")
    st.write(
        "This is a forward test: the agent saves each directional AI assessment with its "
        "gold-price baseline, then scores it against the first completed five-minute close "
        "at or after one hour (within a 10-minute tolerance). Older gold candles alone cannot "
        "recreate historical AI forecasts."
    )
    st.warning(
        "Directional hit rate is not profitability. It excludes mixed/uncertain assessments "
        "and does not account for spread, fees, slippage, trade entries or position sizing. "
        "This is not a trading strategy or a conventional historical backtest."
    )
    if error:
        st.info(error)
    scored = [row for row in rows if row[7] is not None]
    pending = sum(row[9] == "pending" for row in rows)
    expired = sum(row[9] == "expired" for row in rows)
    hits = sum(row[7] for row in scored)
    accuracy = 100 * hits / len(scored) if scored else None
    mean_aligned = (
        sum(row[6] * (1 if row[1] == "up" else -1) for row in scored) / len(scored)
        if scored else None
    )
    cols = st.columns(5)
    cols[0].metric("Scored forecasts", len(scored))
    cols[1].metric("Directional hit rate", "—" if accuracy is None else f"{accuracy:.1f}%")
    cols[2].metric("Waiting for 1-hour outcome", pending)
    cols[3].metric("Expired · market gap", expired)
    cols[4].metric(
        "Mean direction-aligned move",
        "—" if mean_aligned is None else f"{mean_aligned:+.3f}%",
    )
    if not rows:
        st.info("No directional forecasts have been saved yet. Forecasts are recorded when AI and market data are healthy.")
        return
    table = []
    for (created, direction, confidence, model, baseline, target_price, actual,
         correct, target, outcome_status) in rows:
        table.append({
            "Forecast time (UTC)": created,
            "AI view": "Gold up" if direction == "up" else "Gold down",
            "Evidence confidence": confidence,
            "Model": model,
            "Gold baseline": round(baseline, 3),
            "1-hour check": target,
            "Observed gold": None if target_price is None else round(target_price, 3),
            "Gold return": pct(actual),
            "Outcome": ("Waiting" if outcome_status == "pending" else
                        "Expired: no timely price" if outcome_status == "expired" else
                        "Correct" if correct else "Incorrect"),
        })
    st.dataframe(table, use_container_width=True, hide_index=True)
    if scored:
        chart_rows = list(reversed(scored))
        st.caption("Actual gold returns after the forecast; a directional score, not a P&L simulation.")
        aligned = [
            row[6] * 100 if row[1] == "up" else -row[6] * 100
            for row in chart_rows[-50:]
        ]
        st.bar_chart({"Direction-aligned gold return %": aligned})


@st.fragment(run_every="30s")
def dashboard():
    report, error = load_report()
    rows, forecast_error = load_forecasts()
    if error:
        st.info(error)
        st.caption(f"Expected report location: `{REPORT}`")
        return
    st.caption("Local dashboard · refreshes every 30 seconds · does not place trades")
    tabs = st.tabs(["Overview", "News & sources", "Forecast test"])
    with tabs[0]:
        display_report(report)
    with tabs[1]:
        display_news(report)
    with tabs[2]:
        display_forecast_test(rows, forecast_error)


st.title("◈ Gold Desk")
dashboard()
