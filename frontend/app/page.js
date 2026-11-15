"use client";
import { useEffect, useState } from "react";

const API = "";
const inr = (n) =>
  typeof n === "number" ? n.toLocaleString("en-IN", { style: "currency", currency: "INR" }) : "–";

function Err({ r }) {
  return (
    <p className="small" style={{ color: "var(--red)", margin: 0 }}>
      {r.status === 403
        ? "Groww denied access (403). This API key doesn't include this data (e.g. a market-data subscription)."
        : `Failed: ${r.error?.error?.message || JSON.stringify(r.error)}`}
    </p>
  );
}

export default function Home() {
  const [conn, setConn] = useState(null);
  const [margin, setMargin] = useState(null);
  const [holdings, setHoldings] = useState(null);
  const [symbol, setSymbol] = useState("RELIANCE");
  const [quote, setQuote] = useState(null);

  const get = (path) => fetch(API + path).then((r) => r.json());

  useEffect(() => {
    get("/api/groww/status").then(setConn).catch(() =>
      setConn({ connected: false, message: "FastAPI backend isn't reachable on :8000." })
    );
    get("/api/groww/margin").then(setMargin).catch(() => {});
    get("/api/groww/holdings").then(setHoldings).catch(() => {});
  }, []);

  const lookup = (e) => {
    e.preventDefault();
    setQuote({ loading: true });
    get(`/api/groww/quote?symbol=${encodeURIComponent(symbol)}`).then(setQuote);
  };

  const eq = margin?.data?.equity_margin_details;
  const list = holdings?.data?.holdings || [];

  return (
    <main className="wrap">
      <div className="top">
        <div>
          <h1 className="grad" style={{ fontSize: 36 }}>StockMarket</h1>
          <p className="muted small">Your Groww account and a Dow-theory scanner for the Nifty 50.</p>
        </div>
        <span className="pill">
          <span className={`dot ${conn ? (conn.connected ? "on" : "off") : ""}`} />
          {conn ? (conn.connected ? "Groww connected" : "Not connected") : "Checking Groww…"}
        </span>
      </div>

      <a href="/analysis" style={{ textDecoration: "none" }}>
        <div className="card kpi hero" style={{ marginBottom: 14, display: "flex", justifyContent: "space-between", alignItems: "center", gap: 16, flexWrap: "wrap" }}>
          <div>
            <div style={{ fontSize: 22, fontWeight: 800, color: "#fff" }}>Nifty 50 Dow Scanner →</div>
            <div className="muted small" style={{ marginTop: 4 }}>
              Pullbacks to 61.8%, trend on three timeframes, EMA, MACD, RSI and stochastic, scored and ranked.
            </div>
          </div>
          <span className="btn">Open scanner</span>
        </div>
      </a>

      <div className="grid g2">
        <div className="card">
          <h3>Account margin</h3>
          {!margin ? <span className="muted">Loading…</span> : !margin.ok ? <Err r={margin} /> : (
            <table className="t">
              <tbody>
                <tr><td className="muted">Clear cash</td><td style={{ textAlign: "right" }}>{inr(margin.data.clear_cash)}</td></tr>
                <tr><td className="muted">Net margin used</td><td style={{ textAlign: "right" }}>{inr(margin.data.net_margin_used)}</td></tr>
                <tr><td className="muted">Collateral available</td><td style={{ textAlign: "right" }}>{inr(margin.data.collateral_available)}</td></tr>
                <tr><td className="muted">CNC balance</td><td style={{ textAlign: "right" }}>{inr(eq?.cnc_balance_available)}</td></tr>
                <tr><td className="muted">MIS balance</td><td style={{ textAlign: "right" }}>{inr(eq?.mis_balance_available)}</td></tr>
              </tbody>
            </table>
          )}
        </div>

        <div className="card">
          <h3>Holdings</h3>
          {!holdings ? <span className="muted">Loading…</span> : !holdings.ok ? <Err r={holdings} /> : list.length === 0 ? (
            <p className="muted small" style={{ margin: 0 }}>No holdings in this account yet.</p>
          ) : (
            <table className="t">
              <thead><tr><th>Symbol</th><th>Qty</th><th>Avg price</th></tr></thead>
              <tbody>
                {list.map((h) => (
                  <tr key={h.isin || h.trading_symbol}><td>{h.trading_symbol}</td><td>{h.quantity}</td><td>{inr(h.average_price)}</td></tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>

      <div className="card" style={{ marginTop: 14 }}>
        <h3>Live quote · NSE</h3>
        <form onSubmit={lookup} style={{ display: "flex", gap: 10, marginBottom: 12 }}>
          <input className="input" value={symbol} onChange={(e) => setSymbol(e.target.value)} placeholder="e.g. RELIANCE" />
          <button className="btn" type="submit">Get quote</button>
        </form>
        {quote?.loading && <span className="muted small">Loading…</span>}
        {quote && !quote.loading && (quote.ok ? (
          <pre className="small" style={{ margin: 0, overflow: "auto" }}>{JSON.stringify(quote.data, null, 2)}</pre>
        ) : <Err r={quote} />)}
      </div>
    </main>
  );
}
