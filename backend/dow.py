"""Dow-theory trend + weekly 61.8% retracement finder for Nifty 50 stocks.

Method
- Monthly chart gives the primary trend (Dow theory): swing highs/lows are compared;
  higher-highs + higher-lows = UPTREND, lower-highs + lower-lows = DOWNTREND, else SIDEWAYS.
- Weekly chart gives swing pivots (fractals). Each completed leg (pivot -> pivot) is checked:
  the following counter-move's end pivot is a "61.8% retracement" if it retraced
  between 58% and 65% of the leg (tolerance around 0.618).
- Only retracement pivots dated within the last 365 days are reported.
"""
from datetime import datetime, timedelta, timezone

import httpx

NIFTY50 = [
    "ADANIENT", "ADANIPORTS", "APOLLOHOSP", "ASIANPAINT", "AXISBANK", "BAJAJ-AUTO", "BAJFINANCE",
    "BAJAJFINSV", "BEL", "BHARTIARTL", "CIPLA", "COALINDIA", "DRREDDY", "EICHERMOT", "ETERNAL",
    "GRASIM", "HCLTECH", "HDFCBANK", "HDFCLIFE", "HEROMOTOCO", "HINDALCO", "HINDUNILVR", "ICICIBANK",
    "INDUSINDBK", "INFY", "ITC", "JIOFIN", "JSWSTEEL", "KOTAKBANK", "LT", "M&M", "MARUTI", "NESTLEIND",
    "NTPC", "ONGC", "POWERGRID", "RELIANCE", "SBILIFE", "SBIN", "SHRIRAMFIN", "SUNPHARMA", "TATACONSUM",
    "TMPV", "TATASTEEL", "TCS", "TECHM", "TITAN", "TRENT", "ULTRACEMCO", "WIPRO",
]
LOW, HIGH = 0.58, 0.65  # accepted retracement band around 61.8%


def fetch(symbol: str, interval: str, rng: str):
    ticker = "^NSEI" if symbol == "NIFTY50" else f"{symbol}.NS"
    r = httpx.get(
        f"https://query1.finance.yahoo.com/v8/finance/chart/{ticker}",
        params={"interval": interval, "range": rng},
        headers={"User-Agent": "Mozilla/5.0"},
        timeout=20,
    )
    r.raise_for_status()
    res = r.json()["chart"]["result"][0]
    q = res["indicators"]["quote"][0]
    out = []
    vols = q.get("volume") or [0] * len(res["timestamp"])
    for t, o, h, l, c, v in zip(res["timestamp"], q["open"], q["high"], q["low"], q["close"], vols):
        if h is None or l is None or o is None or c is None:
            continue
        out.append({"date": datetime.fromtimestamp(t, timezone.utc).date(), "open": o, "high": h,
                    "low": l, "close": c, "volume": v or 0})
    return out


def pivots(bars, n: int):
    """Fractal pivots: a high/low that is extreme versus n bars on each side."""
    pts = []
    for i in range(n, len(bars) - n):
        win = bars[i - n : i + n + 1]
        if bars[i]["high"] == max(b["high"] for b in win):
            pts.append({"i": i, "date": bars[i]["date"], "price": bars[i]["high"], "type": "H"})
        elif bars[i]["low"] == min(b["low"] for b in win):
            pts.append({"i": i, "date": bars[i]["date"], "price": bars[i]["low"], "type": "L"})
    # keep alternating H/L, retaining the more extreme of consecutive same-type pivots
    zz = []
    for p in pts:
        if zz and zz[-1]["type"] == p["type"]:
            better = p["price"] > zz[-1]["price"] if p["type"] == "H" else p["price"] < zz[-1]["price"]
            if better:
                zz[-1] = p
        else:
            zz.append(p)
    return zz


def trend_of(bars, n=1):
    """Dow trend from swing structure: HH+HL = UPTREND, LH+LL = DOWNTREND, else SIDEWAYS."""
    zz = pivots(bars, n)
    highs = [p["price"] for p in zz if p["type"] == "H"][-2:]
    lows = [p["price"] for p in zz if p["type"] == "L"][-2:]
    if len(highs) < 2 or len(lows) < 2:
        return "SIDEWAYS"
    if highs[1] > highs[0] and lows[1] > lows[0]:
        return "UPTREND"
    if highs[1] < highs[0] and lows[1] < lows[0]:
        return "DOWNTREND"
    return "SIDEWAYS"


def dow_trend(monthly):
    return trend_of(monthly, 1)


def labelled_pivots(bars, n=2):
    """Pivots tagged HH / LH (highs) and HL / LL (lows) versus the previous pivot of the same kind."""
    zz, last, out = pivots(bars, n), {}, []
    for p in zz:
        prev = last.get(p["type"])
        if prev is None:
            label = p["type"]
        elif p["type"] == "H":
            label = "HH" if p["price"] > prev else "LH"
        else:
            label = "HL" if p["price"] > prev else "LL"
        last[p["type"]] = p["price"]
        out.append({"time": p["date"].isoformat(), "price": round(p["price"], 2), "type": p["type"], "label": label})
    return out


def retracements(weekly, since):
    zz = pivots(weekly, 2)
    found = []
    for a, b, c in zip(zz, zz[1:], zz[2:]):
        leg = abs(b["price"] - a["price"])
        if leg == 0 or c["date"] < since:
            continue
        ratio = abs(b["price"] - c["price"]) / leg
        if LOW <= ratio <= HIGH:
            found.append({
                "date": c["date"].isoformat(),
                "direction": "pullback in up-leg" if a["type"] == "L" else "bounce in down-leg",
                "leg_start": {"date": a["date"].isoformat(), "price": round(a["price"], 2)},
                "leg_end": {"date": b["date"].isoformat(), "price": round(b["price"], 2)},
                "retrace_price": round(c["price"], 2),
                "ratio": round(ratio, 3),
            })
    return found



EMA_PERIODS = (20, 50, 100)


def ema(values, n):
    k, out, prev = 2 / (n + 1), [], None
    for v in values:
        prev = v if prev is None else v * k + prev * (1 - k)
        out.append(prev)
    return out


def daily_emas(daily):
    closes = [b["close"] for b in daily]
    return {n: ema(closes, n) for n in EMA_PERIODS}


def daily_crossovers(daily, emas):
    """Price crossover: close moves above ALL of EMA20/50/100 after not being above all three the day before.
    Strict crossover: a price crossover on a day when the EMAs are also bullishly stacked (20 > 50 > 100)."""
    n = len(daily)
    above = [all(daily[i]["close"] > emas[p][i] for p in EMA_PERIODS) for i in range(n)]
    crosses = [i for i in range(1, n) if above[i] and not above[i - 1]]
    strict = [i for i in crosses if emas[20][i] > emas[50][i] > emas[100][i]]
    d = lambda idx: [daily[i]["date"] for i in idx]
    return d(crosses), d(strict), (above[-1] if n else False)


def ema_events(daily, emas):
    """EMA-over-EMA crossovers: 20 crossing above 50, and 50 crossing above 100."""
    out = []
    for i in range(101, len(daily)):
        if emas[20][i] > emas[50][i] and emas[20][i - 1] <= emas[50][i - 1]:
            out.append({"time": daily[i]["date"].isoformat(), "type": "20/50"})
        if emas[50][i] > emas[100][i] and emas[50][i - 1] <= emas[100][i - 1]:
            out.append({"time": daily[i]["date"].isoformat(), "type": "50/100"})
    return out


# ---------- Momentum indicators ----------
# Timeframes (change here): MACD on monthly bars; RSI and Stochastic on MOMENTUM_TF bars ("1d" or "1wk").
MOMENTUM_TF = "1d"
TF_NAME = {"1d": "Daily", "1wk": "Weekly"}
RSI_MIN = 40
STOCH_OVERSOLD = 20


def macd(closes, fast=12, slow=26, sig=9):
    ef, es = ema(closes, fast), ema(closes, slow)
    line = [f - s_ for f, s_ in zip(ef, es)]
    signal = ema(line, sig)
    return line, signal


def rsi(closes, n=14):
    """Wilder RSI."""
    out = [None] * len(closes)
    if len(closes) <= n:
        return out
    gains = [max(closes[i] - closes[i - 1], 0) for i in range(1, len(closes))]
    losses = [max(closes[i - 1] - closes[i], 0) for i in range(1, len(closes))]
    ag, al = sum(gains[:n]) / n, sum(losses[:n]) / n
    out[n] = 100 if al == 0 else 100 - 100 / (1 + ag / al)
    for i in range(n + 1, len(closes)):
        ag = (ag * (n - 1) + gains[i - 1]) / n
        al = (al * (n - 1) + losses[i - 1]) / n
        out[i] = 100 if al == 0 else 100 - 100 / (1 + ag / al)
    return out


def stochastic(bars, k_len=14, k_smooth=3, d_len=3):
    """Slow stochastic (14,3,3): %K smoothed, %D = SMA of %K."""
    raw = []
    for i in range(len(bars)):
        if i < k_len - 1:
            raw.append(None)
            continue
        w = bars[i - k_len + 1 : i + 1]
        hi, lo = max(b["high"] for b in w), min(b["low"] for b in w)
        raw.append(50.0 if hi == lo else 100 * (bars[i]["close"] - lo) / (hi - lo))

    def sma(xs, n):
        return [None if i < n - 1 or any(v is None for v in xs[i - n + 1 : i + 1])
                else sum(xs[i - n + 1 : i + 1]) / n for i in range(len(xs))]

    k = sma(raw, k_smooth)
    return k, sma(k, d_len)


def stoch_crosses(bars, k, d):
    """Positive crossover (%K up through %D) that starts in the oversold zone."""
    out = []
    for i in range(1, len(bars)):
        if None in (k[i], d[i], k[i - 1], d[i - 1]):
            continue
        if k[i] > d[i] and k[i - 1] <= d[i - 1] and min(k[i - 1], d[i - 1]) <= STOCH_OVERSOLD:
            out.append(bars[i]["date"])
    return out


def macd_cross_date(bars, line, signal):
    """Date of the most recent bullish MACD crossover (line up through signal)."""
    for i in range(len(bars) - 1, 0, -1):
        if line[i] > signal[i] and line[i - 1] <= signal[i - 1]:
            return bars[i]["date"].isoformat()
    return None


def momentum_state(monthly, weekly, daily):
    """MACD on monthly and daily bars; RSI and stochastic on `weekly` (really the MOMENTUM_TF bars)."""
    dl, ds = macd([b["close"] for b in daily])
    ml, ms = macd([b["close"] for b in monthly])
    r = rsi([b["close"] for b in weekly])
    k, d = stochastic(weekly)
    return {
        "macd": round(ml[-1], 2), "macd_signal": round(ms[-1], 2), "macd_ok": ml[-1] > ms[-1],
        "macd_d": round(dl[-1], 2), "macd_d_signal": round(ds[-1], 2), "macd_d_ok": dl[-1] > ds[-1],
        "macd_d_cross": macd_cross_date(daily, dl, ds),
        "rsi": round(r[-1], 1) if r[-1] is not None else None,
        "rsi_ok": r[-1] is not None and r[-1] > RSI_MIN,
        "stoch_crosses": stoch_crosses(weekly, k, d),
    }


def _score(trends, mom, hit, last_hit_age_days):
    """Dow-theory setup scorecard for the latest bullish (pullback in up-leg) retracement. Max 100.
    The four momentum rules are hard conditions: unless all pass, the score is capped at 64 (grade C)."""
    pts = {"UPTREND": 1.0, "SIDEWAYS": 0.4, "DOWNTREND": 0.0}
    checks = []

    def add(label, frac, mx, note):
        checks.append({"label": label, "points": round(frac * mx), "max": mx,
                       "ok": frac >= 1, "partial": 0 < frac < 1, "note": note})

    add("Primary trend (monthly HH/HL)", pts[trends["monthly"]], 20, trends["monthly"].lower())
    add("Secondary trend (weekly HH/HL)", pts[trends["weekly"]], 10, trends["weekly"].lower())
    add("Minor trend (daily HH/HL)", pts[trends["daily"]], 5, trends["daily"].lower())
    recent = last_hit_age_days <= 84
    add("61.8% pullback held the prior swing low", 1.0 if recent else 0.5, 10,
        f"{last_hit_age_days} days ago" + ("" if recent else " (older than 12 weeks)"))
    pc, sc = hit["price_cross_date"], hit["ema_cross_date"]
    add("Daily close crossed above EMA 20/50/100, EMAs stacked", 1.0 if sc else 0.5 if pc else 0, 10,
        f"confirmed {sc}" if sc else f"price only {pc}" if pc else "no crossover within 60 days")
    add("Resumption: price broke the prior swing high", 1.0 if hit["resume_date"] else 0, 5,
        hit["resume_date"] or "not yet")
    vr = hit["vol_ratio"]
    add("Volume on confirming day >= 1.2x 20-day average", 1.0 if (vr or 0) >= 1.2 else 0, 5,
        f"{vr}x" if vr else "n/a")
    # --- required momentum conditions ---
    add("Monthly MACD line above signal line", 1.0 if mom["macd_ok"] else 0, 10,
        f"MACD {mom['macd']} vs signal {mom['macd_signal']}")
    dx = mom["macd_d_cross"]
    add("Daily MACD line above signal line", 1.0 if mom["macd_d_ok"] else 0, 5,
        f"MACD {mom['macd_d']} vs signal {mom['macd_d_signal']}" + (f", bullish cross {dx}" if dx and mom["macd_d_ok"] else ""))
    add(f"{TF_NAME[MOMENTUM_TF]} RSI above {RSI_MIN}", 1.0 if mom["rsi_ok"] else 0, 5, f"RSI {mom['rsi']}")
    sx = hit["stoch_cross_date"]
    add(f"{TF_NAME[MOMENTUM_TF]} stochastic: positive cross from oversold", 1.0 if sx else 0, 15,
        sx or "no oversold cross around the pullback")
    momentum_ok = bool(mom["macd_ok"] and mom["macd_d_ok"] and mom["rsi_ok"] and sx)
    score = sum(c["points"] for c in checks)
    capped = None
    if trends["monthly"] == "DOWNTREND":
        score, capped = min(score, 55), "primary (monthly) trend is down: Dow theory says don't fight it"
    if not momentum_ok and score > 64:
        score, capped = 64, "not all momentum conditions (monthly MACD, daily MACD, RSI, stochastic) are met"
    grade = "A" if score >= 80 else "B" if score >= 65 else "C" if score >= 45 else "D"
    return {"score": score, "grade": grade, "checks": checks, "hit_date": hit["date"],
            "momentum_ok": momentum_ok, "capped": capped}


def analyse(symbol: str):
    monthly = fetch(symbol, "1mo", "10y")
    weekly = fetch(symbol, "1wk", "3y")
    daily = fetch(symbol, "1d", "3y")
    today = datetime.now(timezone.utc).date()
    since = today - timedelta(days=365)
    trends = {"monthly": trend_of(monthly, 1), "weekly": trend_of(weekly, 2), "daily": trend_of(daily, 3)}
    mom = momentum_state(monthly, daily if MOMENTUM_TF == "1d" else weekly, daily)
    hits = retracements(weekly, since)
    em = daily_emas(daily)
    crosses, strict, above_now = daily_crossovers(daily, em)
    crosses = [d for d in crosses if d >= since]
    strict = [d for d in strict if d >= since]
    idx = {b["date"]: i for i, b in enumerate(daily)}
    for h in hits:
        d = datetime.fromisoformat(h["date"]).date()
        within = lambda lst: next((c for c in lst if d <= c <= d + timedelta(days=60)), None)
        pc, sc = within(crosses), within(strict)
        h["price_cross_date"] = pc.isoformat() if pc else None
        h["ema_cross_date"] = sc.isoformat() if sc else None
        # stochastic cross from oversold around the pullback low (from 2 weeks before it to 60 days after)
        sx = next((c for c in mom["stoch_crosses"] if d - timedelta(days=14) <= c <= d + timedelta(days=60)), None)
        h["stoch_cross_date"] = sx.isoformat() if sx else None
        up = h["direction"].startswith("pullback")
        lvl = h["leg_end"]["price"]
        h["resume_date"] = next(
            (b["date"].isoformat() for b in daily if b["date"] > d and (b["high"] > lvl if up else b["low"] < lvl)), None)
        cd = sc or pc
        h["vol_ratio"] = None
        if cd and cd in idx and idx[cd] >= 20:
            i = idx[cd]
            avg = sum(b["volume"] for b in daily[i - 20:i]) / 20
            if avg > 0:
                h["vol_ratio"] = round(daily[i]["volume"] / avg, 2)
    bullish = [h for h in hits if h["direction"].startswith("pullback")]
    setup = None
    if bullish:
        latest = max(bullish, key=lambda h: h["date"])
        age = (today - datetime.fromisoformat(latest["date"]).date()).days
        setup = _score(trends, mom, latest, age)
    return {
        "symbol": symbol,
        "monthly_trend": trends["monthly"],
        "trends": trends,
        "momentum": {k_: v for k_, v in mom.items() if k_ != "stoch_crosses"},
        "setup": setup,
        "last_close": round(weekly[-1]["close"], 2),
        "above_all_emas_now": above_now,
        "stacked_now": em[20][-1] > em[50][-1] > em[100][-1],
        "ema_crossovers": [c.isoformat() for c in strict],
        "retracements": hits,
    }


def indicators(symbol: str):
    """Series for the indicator panes: monthly MACD, weekly RSI and weekly stochastic."""
    monthly, weekly = fetch(symbol, "1mo", "10y"), fetch(symbol, MOMENTUM_TF, "3y")
    ml, ms = macd([b["close"] for b in monthly])
    r = rsi([b["close"] for b in weekly])
    k, d = stochastic(weekly)
    today = datetime.now(timezone.utc).date()
    daily = fetch(symbol, "1d", "3y")
    dl, ds = macd([b["close"] for b in daily])
    cut = (today - timedelta(days=800)).isoformat()
    mcut = (today - timedelta(days=2000)).isoformat()
    t = lambda b: b["date"].isoformat()
    return {
        "macd": [{"time": t(b), "macd": round(ml[i], 2), "signal": round(ms[i], 2), "hist": round(ml[i] - ms[i], 2)}
                 for i, b in enumerate(monthly) if i >= 30 and t(b) >= mcut],
        "macd_d": [{"time": t(b), "macd": round(dl[i], 2), "signal": round(ds[i], 2), "hist": round(dl[i] - ds[i], 2)}
                   for i, b in enumerate(daily) if i >= 30 and t(b) >= cut],
        "rsi": [{"time": t(b), "value": round(r[i], 1)} for i, b in enumerate(weekly) if r[i] is not None and t(b) >= cut],
        "stoch": [{"time": t(b), "k": round(k[i], 1), "d": round(d[i], 1)} for i, b in enumerate(weekly)
                  if d[i] is not None and t(b) >= cut],
        "stoch_crosses": [c.isoformat() for c in stoch_crosses(weekly, k, d) if c.isoformat() >= cut],
        "rsi_min": RSI_MIN, "oversold": STOCH_OVERSOLD, "tf": TF_NAME[MOMENTUM_TF],
    }


def candles(symbol: str, interval: str = "1wk"):
    bars = fetch(symbol, interval, "3y")
    daily = bars if interval == "1d" else fetch(symbol, "1d", "3y")
    em = daily_emas(daily)
    price_x, strict_x, _ = daily_crossovers(daily, em)
    return {
        "candles": [
            {"time": b["date"].isoformat(), "open": round(b["open"], 2), "high": round(b["high"], 2),
             "low": round(b["low"], 2), "close": round(b["close"], 2)} for b in bars],
        # daily EMA lines (skip the first 100 bars while the slow EMA warms up)
        "emas": {str(n): [{"time": daily[i]["date"].isoformat(), "value": round(em[n][i], 2)}
                          for i in range(100, len(daily))] for n in EMA_PERIODS},
        "crossovers": [d.isoformat() for d in price_x],
        "strict_crossovers": [d.isoformat() for d in strict_x],
        "ema_events": ema_events(daily, em),
        "pivots": [p for p in labelled_pivots(fetch(symbol, "1wk", "3y"), 2)
                   if p["time"] >= (datetime.now(timezone.utc).date() - timedelta(days=800)).isoformat()],
    }


