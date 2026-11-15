"use client";
import { useEffect, useMemo, useState } from "react";
import Chart from "./Chart";
import Indicators from "./Indicators";
import { T } from "./theme";

const GRADE = { A: "#22c55e", B: "#a3e635", C: "#f59e0b", D: "#64748b" };
const ARROW = { UPTREND: "↑", DOWNTREND: "↓", SIDEWAYS: "→" };
const TCLASS = { UPTREND: "up", DOWNTREND: "down", SIDEWAYS: "side" };
const fmt = (d) =>
  d ? new Date(d).toLocaleDateString("en-IN", { day: "numeric", month: "short", year: "2-digit" }) : "–";
const inr = (n) => "₹" + Number(n).toLocaleString("en-IN", { maximumFractionDigits: 2 });

// ---------- small pieces ----------
function Ring({ setup, size = 48 }) {
  const r = size / 2 - 5, c = 2 * Math.PI * r;
  const score = setup?.score ?? 0;
  const col = setup ? GRADE[setup.grade] : "#334166";
  return (
    <div style={{ position: "relative", width: size, height: size }}>
      <svg width={size} height={size} style={{ transform: "rotate(-90deg)" }}>
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="#1d2850" strokeWidth="5" />
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={col} strokeWidth="5" strokeLinecap="round"
          strokeDasharray={`${(score / 100) * c} ${c}`} style={{ filter: setup ? `drop-shadow(0 0 4px ${col})` : "none" }} />
      </svg>
      <div style={{ position: "absolute", inset: 0, display: "grid", placeItems: "center", fontWeight: 800, fontSize: size * 0.3 }}>
        {setup ? score : "–"}
      </div>
    </div>
  );
}

function TrendChips({ trends }) {
  return (
    <span className="chips">
      {[["M", "monthly", "Primary"], ["W", "weekly", "Secondary"], ["D", "daily", "Minor"]].map(([l, k, name]) => (
        <span key={k} className={`chip ${TCLASS[trends[k]]}`} title={`${name} trend (${k}): ${trends[k].toLowerCase()}`}>
          {l} {ARROW[trends[k]]}
        </span>
      ))}
    </span>
  );
}

function Momentum({ r }) {
  const m = r.momentum;
  const stoch = r.setup?.checks?.[r.setup.checks.length - 1]?.ok;
  const items = [
    ["MACD M", m.macd_ok, `Monthly MACD ${m.macd} vs signal ${m.macd_signal}`],
    ["MACD D", m.macd_d_ok, `Daily MACD ${m.macd_d} vs signal ${m.macd_d_signal}`],
    ["RSI", m.rsi_ok, `RSI ${m.rsi}`],
    ["STOCH", r.setup ? !!stoch : null, "Stochastic positive cross from oversold around the pullback"],
  ];
  return (
    <span className="chips">
      {items.map(([l, ok, tip]) => (
        <span key={l} title={tip} className={`chip ${ok === null ? "" : ok ? "pass" : "fail"}`}>
          {ok === null ? "·" : ok ? "✔" : "✗"} {l}
        </span>
      ))}
    </span>
  );
}

function Gauge({ ratio }) {
  const pos = (v) => `${v * 100}%`;
  return (
    <div style={{ position: "relative", width: 90, height: 8, background: "#1d2850", borderRadius: 4 }}>
      <div style={{ position: "absolute", left: pos(0.58), width: pos(0.07), top: 0, bottom: 0, background: "rgba(245,158,11,.35)" }} />
      <div style={{ position: "absolute", left: pos(0.618), top: -2, bottom: -2, width: 2, background: T.amber }} />
      <div style={{ position: "absolute", left: pos(ratio), top: -3, width: 6, height: 14, marginLeft: -3, background: "#fff", borderRadius: 3 }} />
    </div>
  );
}

// ---------- detail tabs ----------
function Checklist({ r }) {
  const s = r.setup;
  return (
    <div>
      {!s ? (
        <p className="muted">No bullish 61.8% pullback in the last 12 months, so there's no setup to score.</p>
      ) : (
        <>
          {s.checks.map((c) => {
            const col = c.ok ? T.green : c.partial ? T.amber : T.red;
            return (
              <div className="check" key={c.label}>
                <b style={{ color: col }}>{c.ok ? "✔" : c.partial ? "◐" : "✗"}</b>
                <div>
                  {c.label}
                  <div className="muted tiny">{c.note}</div>
                </div>
                <div className="bar-track hide-s">
                  <div className="bar-fill" style={{ width: `${(c.points / c.max) * 100}%`, background: col }} />
                </div>
                <div style={{ textAlign: "right" }} className="small">{c.points}/{c.max}</div>
              </div>
            );
          })}
          {s.capped && <p className="tiny" style={{ color: T.amber, marginTop: 10 }}>Score capped: {s.capped}.</p>}
        </>
      )}

      {r.retracements.length > 0 && (
        <>
          <h3 style={{ margin: "22px 0 4px", fontSize: 14, color: "var(--muted)", textTransform: "uppercase", letterSpacing: ".06em" }}>
            61.8% retracements · last 12 months
          </h3>
          <div style={{ overflowX: "auto" }}>
            <table className="t">
              <thead>
                <tr><th>Week of</th><th>Type</th><th>Swing leg</th><th>Retraced to</th><th>Depth</th><th>EMA confirm</th></tr>
              </thead>
              <tbody>
                {r.retracements.map((x) => (
                  <tr key={x.date}>
                    <td>{fmt(x.date)}</td>
                    <td style={{ color: x.direction.startsWith("pullback") ? T.green : T.red }}>
                      {x.direction.startsWith("pullback") ? "▲ dip in up-leg" : "▼ bounce in down-leg"}
                    </td>
                    <td className="muted">{x.leg_start.price} → {x.leg_end.price}</td>
                    <td>{x.retrace_price}</td>
                    <td><span style={{ display: "inline-flex", gap: 8, alignItems: "center" }}><Gauge ratio={x.ratio} />{(x.ratio * 100).toFixed(1)}%</span></td>
                    <td style={{ color: x.ema_cross_date ? T.green : x.price_cross_date ? T.amber : "var(--muted)" }}>
                      {x.ema_cross_date ? `✔ ${fmt(x.ema_cross_date)}` : x.price_cross_date ? `price only · ${fmt(x.price_cross_date)}` : "–"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}

function Detail({ r }) {
  const [tab, setTab] = useState("chart");
  return (
    <div className="detail">
      <div className="tabs">
        {[["chart", "Price & structure"], ["momentum", "Momentum"], ["check", "Checklist"]].map(([k, l]) => (
          <button key={k} className={tab === k ? "on" : ""} onClick={() => setTab(k)}>{l}</button>
        ))}
      </div>
      {tab === "chart" && <Chart symbol={r.symbol} retracements={r.retracements} />}
      {tab === "momentum" && <Indicators symbol={r.symbol} />}
      {tab === "check" && <Checklist r={r} />}
    </div>
  );
}

function Row({ r, open, onToggle }) {
  const s = r.setup;
  return (
    <div className={`item ${open ? "open" : ""}`}>
      <div className="row" onClick={onToggle}>
        <Ring setup={s} />
        <div>
          <div className="sym">
            {r.symbol} {s?.momentum_ok && <span className="chip star" style={{ marginLeft: 6 }}>Qualified</span>}
          </div>
          <div className="muted tiny">{inr(r.last_close)}{s ? ` · pullback ${fmt(s.hit_date)}` : " · no bullish pullback"}</div>
        </div>
        <div className="hide-s"><TrendChips trends={r.trends} /></div>
        <div className="hide-s"><Momentum r={r} /></div>
        <div className="muted" style={{ textAlign: "right", transform: open ? "rotate(180deg)" : "none", transition: ".2s" }}>▾</div>
      </div>
      {open && <Detail r={r} />}
    </div>
  );
}

// ---------- page ----------
export default function Analysis() {
  const [data, setData] = useState(null);
  const [err, setErr] = useState(null);
  const [filter, setFilter] = useState("setup");
  const [q, setQ] = useState("");
  const [open, setOpen] = useState(null);
  const [how, setHow] = useState(false);

  useEffect(() => {
    fetch("http://localhost:8000/api/analysis/dow")
      .then((r) => r.json())
      .then((d) => {
        setData(d);
        const pick = d.results.find((r) => r.setup?.momentum_ok) || d.results.find((r) => r.setup);
        pick && setOpen(pick.symbol);
      })
      .catch(() => setErr("Can't reach the backend on :8000. Is uvicorn running?"));
  }, []);

  const stats = useMemo(() => {
    if (!data) return null;
    const ok = data.results.filter((r) => !r.error && r.symbol !== "NIFTY50");
    const counts = { UPTREND: 0, DOWNTREND: 0, SIDEWAYS: 0 };
    ok.forEach((r) => counts[r.monthly_trend]++);
    const now = new Date();
    const months = Array.from({ length: 12 }, (_, i) => {
      const d = new Date(now.getFullYear(), now.getMonth() - (11 - i), 1);
      return { key: d.toISOString().slice(0, 7), label: d.toLocaleString("en", { month: "short" }), up: 0, down: 0 };
    });
    let hits = 0;
    ok.forEach((r) => r.retracements.forEach((x) => {
      hits++;
      const m = months.find((m) => m.key === x.date.slice(0, 7));
      if (m) x.direction.startsWith("pullback") ? m.up++ : m.down++;
    }));
    return {
      n: ok.length, counts, months, hits,
      qualified: ok.filter((r) => r.setup?.momentum_ok).length,
      aboveEma: ok.filter((r) => r.above_all_emas_now).length,
    };
  }, [data]);

  if (err) return <main className="wrap"><div className="card" style={{ color: T.red }}>{err}</div></main>;
  if (!data) return (
    <main className="wrap">
      <div className="empty">Scanning Nifty 50 across monthly, weekly and daily charts…<br /><span className="tiny">first load takes ~20 seconds</span></div>
    </main>
  );

  const FILTERS = [
    ["setup", "With setup", (r) => r.setup],
    ["qualified", "Qualified", (r) => r.setup?.momentum_ok],
    ["uptrend", "Uptrend", (r) => r.trends.monthly === "UPTREND"],
    ["all", "All", () => true],
  ];
  const test = FILTERS.find((f) => f[0] === filter)[2];
  const rows = data.results
    .filter((r) => !r.error)
    .filter(test)
    .filter((r) => r.symbol.includes(q.trim().toUpperCase()))
    .sort((a, b) => (b.setup?.score ?? -1) - (a.setup?.score ?? -1));
  const maxM = Math.max(1, ...stats.months.map((m) => m.up + m.down));

  return (
    <main className="wrap">
      <div className="top">
        <div>
          <a className="tiny" href="/">← Home</a>
          <h1 className="grad" style={{ marginTop: 8 }}>Nifty 50 Dow Scanner</h1>
          <p className="muted small">
            Finds clean pullbacks inside uptrends: Dow trend on three timeframes, a 61.8% retracement, then momentum and EMA confirmation.
          </p>
        </div>
        <button className="linkbtn" onClick={() => setHow(!how)}>{how ? "Hide" : "How it works"}</button>
      </div>

      {how && (
        <div className="card howto" style={{ marginBottom: 14 }}>
          <b>The method</b>
          <ul>
            <li><b>Dow trend</b> on monthly (primary), weekly (secondary) and daily (minor): higher highs + higher lows = uptrend.</li>
            <li><b>Pullback:</b> a weekly counter-move that retraced 58–65% of the last swing, within 12 months.</li>
            <li><b>EMA confirm:</b> within 60 days the close crosses above EMA 20/50/100 while they're stacked 20 &gt; 50 &gt; 100.</li>
            <li><b>Momentum rules (all required):</b> monthly MACD above signal, daily MACD above signal, daily RSI above 40, daily stochastic crossing up from below 20.</li>
            <li><b>Score</b> (0–100): trends 35, pullback 10, EMA 10, resumption 5, volume 5, momentum 35. Fail any momentum rule and the score is capped at 64; a down monthly trend caps it at 55.</li>
          </ul>
        </div>
      )}

      <div className="grid g4">
        <div className="card kpi hero"><div className="v grad">{stats.qualified}</div><div className="l">Qualified setups</div></div>
        <div className="card kpi"><div className="v">{stats.counts.UPTREND}<span className="muted" style={{ fontSize: 16 }}> / {stats.n}</span></div><div className="l">In primary uptrend</div></div>
        <div className="card kpi"><div className="v">{stats.aboveEma}<span className="muted" style={{ fontSize: 16 }}> / {stats.n}</span></div><div className="l">Above EMA 20/50/100</div></div>
        <div className="card kpi"><div className="v">{stats.hits}</div><div className="l">Pullbacks in 12 months</div></div>
      </div>

      <div className="grid g2" style={{ marginTop: 14 }}>
        <div className="card">
          <h3>Market trend · monthly</h3>
          <div style={{ display: "flex", height: 14, borderRadius: 8, overflow: "hidden", marginBottom: 12 }}>
            {[["UPTREND", T.green], ["SIDEWAYS", T.amber], ["DOWNTREND", T.red]].map(([k, c]) => (
              <div key={k} style={{ width: `${(stats.counts[k] / stats.n) * 100}%`, background: c }} />
            ))}
          </div>
          <div className="chips">
            <span className="chip up">{stats.counts.UPTREND} up</span>
            <span className="chip side">{stats.counts.SIDEWAYS} sideways</span>
            <span className="chip down">{stats.counts.DOWNTREND} down</span>
          </div>
        </div>
        <div className="card">
          <h3>Pullbacks by month</h3>
          <div className="mbars">
            {stats.months.map((m) => (
              <div className="c" key={m.key}>
                <div>{m.up + m.down || ""}</div>
                <div className="stack">
                  <div style={{ height: `${(m.down / maxM) * 100}%`, background: T.red }} />
                  <div style={{ height: `${(m.up / maxM) * 100}%`, background: T.green }} />
                </div>
                {m.label}
              </div>
            ))}
          </div>
        </div>
      </div>

      <div className="bar">
        <div className="seg">
          {FILTERS.map(([k, l]) => (
            <button key={k} className={filter === k ? "on" : ""} onClick={() => setFilter(k)}>{l}</button>
          ))}
        </div>
        <input className="input" placeholder="Search symbol…" value={q} onChange={(e) => setQ(e.target.value)} />
        <span className="muted small" style={{ marginLeft: "auto" }}>{rows.length} stocks</span>
      </div>

      {rows.length === 0 && <div className="card empty">Nothing matches. Try a wider filter.</div>}
      {rows.map((r) => (
        <Row key={r.symbol} r={r} open={open === r.symbol} onToggle={() => setOpen(open === r.symbol ? null : r.symbol)} />
      ))}

      <p className="note">
        Data from Yahoo Finance (Groww's market-data API isn't enabled for this key). This is a screening aid built on
        pattern rules; it isn't investment advice and hasn't been backtested.
      </p>
    </main>
  );
}
