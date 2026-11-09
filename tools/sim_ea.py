"""Approximate opening-range EA simulation; not an MT5 tick or margin test."""
import argparse
import csv, math, os, datetime as D
from collections import defaultdict

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("csv", help="MT5 tab-separated M1 OHLC export with spread in points")
parser.add_argument("--broker-dst", choices=("none", "europe"), default="europe")
parser.add_argument("--balance", type=float, default=1000)
parser.add_argument("--lots", type=float, default=0.04)
parser.add_argument("--stop-buffer-price", type=float, default=1.0,
                    help="Price units beyond the opposite M15 range boundary (default 1.000)")
parser.add_argument("--verbose", action="store_true", help="Print completed trades")
parser.add_argument("--entry-minutes", type=int, choices=(5, 15), default=5,
                    help="Breakout confirmation candle duration; opening range stays M15")
args = parser.parse_args()
if not math.isfinite(args.stop_buffer_price) or args.stop_buffer_price < 0:
    parser.error("--stop-buffer-price must be nonnegative and finite")
if not math.isfinite(args.balance) or args.balance <= 0:
    parser.error("--balance must be positive and finite")
if not math.isfinite(args.lots) or args.lots < 0.02 or abs(args.lots / 0.02 - round(args.lots / 0.02)) > 1e-8:
    parser.error("--lots must be a positive multiple of 0.02 for valid 50% halves")
DST = args.broker_dst
RISK = 1.0  # Used only when overriding fixed sizing for research.
START = args.balance
os.environ["LOTS"] = str(args.lots)
for key, value in {"SKIP": "NY", "NOMID": "Asian,London,NY", "BE_R": "1"}.items():
    os.environ.setdefault(key, value)
POINT, CONTRACT, STEP, MINLOT = 0.001, 100.0, 0.01, 0.01
BUFFER, DEV, ATRP, TRAIL = args.stop_buffer_price, 20 * POINT, 14, 2.0
BASE = 2 * 3600
SESS = [("Asian", 60), ("London", 660), ("NY", 810)]

def last_sunday(y, m):
    d = D.datetime(y, m + 1, 1) - D.timedelta(days=1) if m < 12 else D.datetime(y, 12, 31)
    return d - D.timedelta(days=(d.weekday() + 1) % 7)

def eu_dst(utc):
    return last_sunday(utc.year, 3).replace(hour=1) <= utc < last_sunday(utc.year, 10).replace(hour=1)

def us_dst(utc):
    y = utc.year
    m1 = D.datetime(y, 3, 1); s = m1 + D.timedelta(days=(6 - m1.weekday()) % 7 + 7)
    n1 = D.datetime(y, 11, 1); e = n1 + D.timedelta(days=(6 - n1.weekday()) % 7)
    return s.replace(hour=7) <= utc < e.replace(hour=6)

def session_utc(ref, s):
    utc = ref - D.timedelta(hours=0 if s == 2 else 2)
    if s == 2 and us_dst(utc): utc -= D.timedelta(hours=1)
    elif s == 1 and eu_dst(utc - D.timedelta(hours=1)): utc -= D.timedelta(hours=1)
    return utc

def to_server(utc):
    return utc + D.timedelta(seconds=BASE + (3600 if DST == "europe" and eu_dst(utc) else 0))

def floor(t, m): return t - D.timedelta(minutes=t.minute % m, seconds=t.second)
def ceil15(t): f = floor(t, 15); return f if f == t else f + D.timedelta(minutes=15)

# ---- data
with open(args.csv, encoding="utf-8-sig", newline="") as data:
    reader = csv.reader(data, delimiter="\t")
    header = next(reader)
    expected = ["<DATE>", "<TIME>", "<OPEN>", "<HIGH>", "<LOW>", "<CLOSE>", "<TICKVOL>", "<VOL>", "<SPREAD>"]
    if header != expected:
        parser.error("CSV header must match an MT5 M1 export: " + "\t".join(expected))
    rows = list(reader)
if not rows:
    parser.error("CSV has no price bars")
bars = [(D.datetime.strptime(r[0] + " " + r[1], "%Y.%m.%d %H:%M:%S"), float(r[2]), float(r[3]),
         float(r[4]), float(r[5]), int(r[8]) * POINT) for r in rows]
if any(bars[i][0] <= bars[i - 1][0] for i in range(1, len(bars))):
    parser.error("CSV timestamps must be strictly increasing")

def agg(mins):
    out = {}
    for t, o, h, l, c, sp in bars:
        k = floor(t, mins)
        if k not in out: out[k] = [o, h, l, c]
        else: b = out[k]; b[1] = max(b[1], h); b[2] = min(b[2], l); b[3] = c
    return out
m5, m15 = agg(5), agg(15)
m15k = sorted(m15)
atr = {}  # ATR (SMA of TR, MT5 iATR) available at close of each M15 bar, keyed by close time
trs = []
for i, k in enumerate(m15k):
    o, h, l, c = m15[k]
    pc = m15[m15k[i - 1]][3] if i else c
    trs.append(max(h, pc) - min(l, pc))
    if len(trs) >= ATRP: atr[k + D.timedelta(minutes=15)] = sum(trs[-ATRP:]) / ATRP

# ---- ranges
ranges = []
d0, d1 = bars[0][0].date(), bars[-1][0].date()
day = d0
while day <= d1:
    mid = D.datetime.combine(day, D.time())
    for s, (name, mins) in enumerate(SESS):
        ref = mid + D.timedelta(minutes=mins)
        ou = session_utc(ref, s)
        nxt = min(c for dd in range(-1, 4) for j, (_, mm) in enumerate(SESS)
                  for c in [session_utc(mid + D.timedelta(days=dd, minutes=mm), j)] if c > ou)
        start = to_server(ou); rs = ceil15(start)
        if rs in m15:
            o, h, l, c = m15[rs]
            if h > l:
                ranges.append(dict(name=name, start=start, rs=rs, end=rs + D.timedelta(minutes=15),
                                   next=to_server(nxt), hi=h, lo=l, mid=(h + l) / 2,
                                   dir=0, conf=None, first=None, second=None, done=False,
                                   profit=False, second_tried=False))
    day += D.timedelta(days=1)

# Breakout confirmation changes independently of the opening range and exit rules.
entry_bars = m5 if args.entry_minutes == 5 else m15
for r in ranges:
    t = r["end"]
    while t + D.timedelta(minutes=args.entry_minutes) < r["next"]:
        if t in entry_bars:
            c = entry_bars[t][3]
            if c > r["hi"] or c < r["lo"]:
                r["dir"] = 1 if c > r["hi"] else -1
                r["conf"] = t + D.timedelta(minutes=args.entry_minutes)
                break
        t += D.timedelta(minutes=args.entry_minutes)

if os.environ.get("NY_SWEEP"):
    for r in ranges:
        if r["name"] != "NY":
            continue
        london = next((x for x in ranges if x["name"] == "London" and
                       x["start"].date() == r["start"].date()), None)
        r["conf"] = None
        r["dir"] = 0
        if london is None:
            continue
        t = ceil15(r["start"])
        while t + D.timedelta(minutes=5) < r["next"]:
            candle = m5.get(t)
            if candle:
                _, high, low, close_price = candle
                inside = london["lo"] < close_price < london["hi"]
                high_sweep = high > london["hi"]
                low_sweep = low < london["lo"]
                # Double-sided sweeps have no unambiguous direction.
                if inside and high_sweep != low_sweep:
                    r["dir"] = -1 if high_sweep else 1
                    r["conf"] = t + D.timedelta(minutes=5)
                    r["sweep_stop"] = high + BUFFER if high_sweep else low - BUFFER
                    break
            t += D.timedelta(minutes=5)

# ---- simulation
balance = START
positions, trades, equity_curve = [], [], []

def volume_for(entry, sl):
    if os.environ.get("LOTS"): return float(os.environ["LOTS"])
    loss = (abs(entry - sl) + DEV) * CONTRACT
    if os.environ.get("FIXRR"):
        v = math.floor(balance * RISK / 100 / loss / STEP + 1e-9) * STEP
        return round(v, 2) if v >= MINLOT else 0.0
    v = math.floor(balance * RISK / 100 / loss / (2 * STEP) + 1e-9) * 2 * STEP
    return round(v, 2) if v / 2 >= MINLOT else 0.0

def open_pos(r, kind, buy, price, t):
    sl = (r["lo"] - BUFFER) if buy else (r["hi"] + BUFFER)
    if r.get("sweep_stop") is not None and kind == "high":
        sl = r["sweep_stop"]
        if (buy and sl >= price) or (not buy and sl <= price):
            trades.append(dict(t=t, sess=r["name"], kind=kind, skipped="sweep stop crossed at entry"))
            return None
    vol = volume_for(price, sl)
    if vol <= 0:
        trades.append(dict(t=t, sess=r["name"], kind=kind, skipped="volume")); return None
    p = dict(r=r, kind=kind, buy=buy, entry=price, sl=sl, risk=abs(price - sl), vol=vol, rem=vol,
             scaled=False, t=t, pnl=0.0)
    positions.append(p); return p

def close(p, price, vol, t, why):
    global balance
    pnl = ((price - p["entry"]) if p["buy"] else (p["entry"] - price)) * vol * CONTRACT
    balance += pnl; p["pnl"] += pnl; p["rem"] = round(p["rem"] - vol, 2)
    if pnl > 0: p["r"]["profit"] = True
    if p["rem"] <= 1e-9:
        positions.remove(p)
        if os.environ.get("REVERSAL") and p["kind"] == "high":
            if os.environ.get("UNLOCK") or (
                why == "SL" and abs(price - p["entry"]) < 1e-8 and not p["scaled"] and not p["r"]["profit"]
            ):
                p["r"]["be_exit"] = t + D.timedelta(minutes=1)
        trades.append(dict(t=p["t"], out=t, sess=p["r"]["name"], kind=p["kind"],
                           side="BUY" if p["buy"] else "SELL", entry=p["entry"], vol=p["vol"],
                           pnl=p["pnl"], why=why, rs=p["r"]["start"]))

conf_at = defaultdict(list)
for r in ranges:
    if r["conf"] and r["name"] not in os.environ.get("SKIP", "").split(","): conf_at[r["conf"]].append(r)
prev_t = None
for t, o, h, l, c, sp in bars:
    # first entry: first tick of the M5 bar right after confirmation
    if t.minute % 5 == 0 or (prev_t and floor(prev_t, 5) != floor(t, 5)):
        k = floor(t, 5)
        for r in conf_at.get(k, []):
            if not r["first"] and not r["profit"]:
                buy = r["dir"] == 1
                r["first"] = open_pos(r, "high", buy, o + sp if buy else o, t) or "skip"
        if os.environ.get("REVERSAL"):
            for r in ranges:
                if not r.get("be_exit") or r.get("reversal_tried") or (r["profit"] and not os.environ.get("UNLOCK")):
                    continue
                if k <= r["be_exit"] or k >= r["next"]:
                    continue
                confirmation_minutes = int(os.environ.get("REV_MIN", "5"))
                if k != floor(k, confirmation_minutes):
                    continue
                confirmation_bars = m15 if confirmation_minutes == 15 else m5
                previous = confirmation_bars.get(k - D.timedelta(minutes=confirmation_minutes))
                if previous is None:
                    continue
                opposite_break = previous[3] < r["lo"] if r["dir"] == 1 else previous[3] > r["hi"]
                if opposite_break:
                    r["reversal_tried"] = True
                    buy = r["dir"] == -1
                    open_pos(r, "reversal", buy, o + sp if buy else o, t)
    # stops (conservative: adverse extreme first)
    for p in list(positions):
        if p["buy"] and l <= p["sl"]: close(p, min(o, p["sl"]), p["rem"], t, "SL")
        elif not p["buy"] and h + sp >= p["sl"]: close(p, max(o + sp, p["sl"]), p["rem"], t, "SL")
    # second (midpoint) entry: first open and in drawdown, no profit yet, before next session
    for r in ranges:
        f = r["first"]
        if r["name"] in os.environ.get("NOMID", "").split(","): continue
        if not isinstance(f, dict) or f not in positions or r["second_tried"] or r["profit"] or t >= r["next"]:
            continue
        if f["buy"] and l + sp <= r["mid"] and r["mid"] < f["entry"]:
            r["second_tried"] = True; r["second"] = open_pos(r, "mid", True, min(o + sp, r["mid"]), t)
        elif not f["buy"] and h >= r["mid"] and r["mid"] > f["entry"]:
            r["second_tried"] = True; r["second"] = open_pos(r, "mid", False, max(o, r["mid"]), t)
    # 2R scale-out, then break-even / ATR trail on bar close
    a = atr.get(floor(t, 15)) or atr.get(max((k for k in atr if k <= t), default=None))
    for p in list(positions):
        tgt = p["entry"] + 2 * p["risk"] if p["buy"] else p["entry"] - 2 * p["risk"]
        if os.environ.get("BE_R") and not p["scaled"]:
            executable = c if p["buy"] else c + sp
            gain = executable - p["entry"] if p["buy"] else p["entry"] - executable
            if gain >= float(os.environ["BE_R"]) * p["risk"]:
                p["sl"] = max(p["sl"], p["entry"]) if p["buy"] else min(p["sl"], p["entry"])
                if os.environ.get("HALF_AT_BE"):
                    p["scaled"] = True
                    close(p, executable, round(p["vol"] / 2, 2), t, "BE-half")
        if not os.environ.get("HALF_AT_BE") and not p["scaled"] and (h >= tgt if p["buy"] else l + sp <= tgt):
            p["scaled"] = True
            partial = round(p["vol"] * float(os.environ.get("SCALE_FRACTION", "0.5")), 2)
            if not os.environ.get("FIXRR"):
                assert partial >= MINLOT and round(p["vol"] - partial, 2) >= MINLOT
            close(p, tgt, p["rem"] if os.environ.get("FIXRR") else partial, t, "2R")
        if p["scaled"] and p in positions:
            mkt = c if p["buy"] else c + sp
            be = p["entry"]
            st = max(be, mkt - TRAIL * a) if p["buy"] else min(be, mkt + TRAIL * a)
            if (p["buy"] and st > p["sl"] and st < mkt) or (not p["buy"] and st < p["sl"] and st > mkt):
                p["sl"] = st
    eq = balance + sum(((c - p["entry"]) if p["buy"] else (p["entry"] - c - sp)) * p["rem"] * CONTRACT
                       for p in positions)
    equity_curve.append(eq); prev_t = t
for p in list(positions): close(p, bars[-1][4], p["rem"], bars[-1][0], "END")

# ---- report
done = [x for x in trades if "pnl" in x]
if os.environ.get("REVERSAL"):
    for r in ranges:
        group = [x for x in done if x["rs"] == r["start"] and x["sess"] == r["name"]]
        assert len(group) <= 2
        reverse = [x for x in group if x["kind"] == "reversal"]
        if reverse:
            first = next(x for x in group if x["kind"] == "high")
            if not os.environ.get("UNLOCK"):
                assert abs(first["pnl"]) < 1e-8
            assert reverse[0]["side"] != first["side"]
            assert first["out"] < reverse[0]["t"] < r["next"]
wins = [x for x in done if x["pnl"] > 0]; losses = [x for x in done if x["pnl"] <= 0]
peak, mdd = START, 0
for e in equity_curve: peak = max(peak, e); mdd = max(mdd, (peak - e) / peak)
gp, gl = sum(x["pnl"] for x in wins), -sum(x["pnl"] for x in losses)
print("Approximate M1 replay: no commissions, swaps, margin/stop-outs or broker execution restrictions.")
print(f"Broker DST={DST} fixed lots={args.lots}  ranges={len(ranges)} signals={sum(1 for r in ranges if r['conf'])}")
print(f"Stop buffer={BUFFER:.3f} price units")
print(f"Entry confirmation=M{args.entry_minutes}; opening range=M15")
print(f"Trades {len(done)}  skipped(volume) {sum(1 for x in trades if x.get('skipped'))}")
print(f"Net {balance - START:+.2f}  final {balance:.2f}  winrate {len(wins)/max(1,len(done))*100:.1f}%  "
      f"PF {gp/gl if gl else float('inf'):.2f}  maxDD {mdd*100:.1f}%")
by = defaultdict(lambda: [0, 0, 0.0])
for x in done:
    k = (x["sess"], x["kind"]); by[k][0] += 1; by[k][1] += x["pnl"] > 0; by[k][2] += x["pnl"]
for k in sorted(by): n, w, pl = by[k]; print(f"  {k[0]:6} {k[1]:4} n={n:3} win={w/n*100:5.1f}% pnl={pl:+9.2f}")
if os.environ.get("BE_R"):
    print("Losses", len([x for x in done if x["pnl"] < -0.005]),
          "flat", len([x for x in done if abs(x["pnl"]) <= 0.005]))
    monthly = defaultdict(float)
    for x in done:
        monthly[x["out"].strftime("%Y-%m")] += x["pnl"]
    print("Monthly P&L", dict(sorted(monthly.items())))
    if os.environ.get("NY_SWEEP"):
        print("Sweep signals", sum(r.get("sweep_stop") is not None for r in ranges))
        print("Crossed sweep stops", sum(x.get("skipped") == "sweep stop crossed at entry" for x in trades))
if args.verbose:
    for x in done:
        print(f"{x['t']} {x['sess']:6} {x['kind']:4} {x['side']:4} {x['entry']:.3f} {x['vol']:.2f} "
              f"-> {x['out']} {x['why']:3} {x['pnl']:+8.2f}")
