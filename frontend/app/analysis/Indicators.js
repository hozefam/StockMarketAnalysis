"use client";
import { useEffect, useRef, useState } from "react";
import { createChart, LineStyle } from "lightweight-charts";
import { T, chartOptions } from "./theme";

const hline = (series, price, color) =>
  series.createPriceLine({ price, color, lineWidth: 1, lineStyle: LineStyle.Dashed, axisLabelVisible: true, title: "" });

function macdPane(el, data) {
  const c = createChart(el, chartOptions(170));
  c.addHistogramSeries({ priceLineVisible: false, lastValueVisible: false })
    .setData(data.map((p) => ({ time: p.time, value: p.hist, color: p.hist >= 0 ? "rgba(34,197,94,.55)" : "rgba(244,63,94,.55)" })));
  c.addLineSeries({ color: T.cyan, lineWidth: 2, title: "MACD", priceLineVisible: false })
    .setData(data.map((p) => ({ time: p.time, value: p.macd })));
  c.addLineSeries({ color: T.amber, lineWidth: 2, title: "Signal", priceLineVisible: false })
    .setData(data.map((p) => ({ time: p.time, value: p.signal })));
  c.timeScale().fitContent();
  return c;
}

export default function Indicators({ symbol }) {
  const macdBox = useRef(null), macdDBox = useRef(null), rsiBox = useRef(null), stBox = useRef(null);
  const [state, setState] = useState("loading");
  const [tf, setTf] = useState("Daily");

  useEffect(() => {
    let charts = [], dead = false;
    fetch(`http://localhost:8000/api/analysis/indicators?symbol=${encodeURIComponent(symbol)}`)
      .then((r) => r.json())
      .then((d) => {
        if (dead) return;
        if (!d.ok) return setState("error");
        setState("ready");
        setTf(d.tf);

        const c1 = macdPane(macdBox.current, d.macd);
        const c0 = macdPane(macdDBox.current, d.macd_d);

        const c2 = createChart(rsiBox.current, chartOptions(150));
        const rs = c2.addLineSeries({ color: "#a78bfa", lineWidth: 2, title: "RSI", priceLineVisible: false });
        rs.setData(d.rsi);
        hline(rs, d.rsi_min, T.red);
        hline(rs, 70, "#4b5a82");
        c2.timeScale().fitContent();

        const c3 = createChart(stBox.current, chartOptions(160));
        const k = c3.addLineSeries({ color: T.cyan, lineWidth: 2, title: "%K", priceLineVisible: false });
        const dd = c3.addLineSeries({ color: T.amber, lineWidth: 1, title: "%D", priceLineVisible: false });
        k.setData(d.stoch.map((p) => ({ time: p.time, value: p.k })));
        dd.setData(d.stoch.map((p) => ({ time: p.time, value: p.d })));
        hline(k, d.oversold, T.green);
        hline(k, 80, "#4b5a82");
        k.setMarkers(d.stoch_crosses.map((t) => ({ time: t, position: "belowBar", shape: "arrowUp", color: T.green, text: "" })));
        c3.timeScale().fitContent();

        charts = [c1, c0, c2, c3];
      })
      .catch(() => !dead && setState("error"));
    return () => { dead = true; charts.forEach((c) => c.remove()); };
  }, [symbol]);

  const Title = ({ children, rule }) => (
    <div style={{ margin: "16px 0 6px" }}>
      <b style={{ fontSize: 14 }}>{children}</b> <span className="muted tiny">· {rule}</span>
    </div>
  );
  const frame = { borderRadius: 12, overflow: "hidden" };

  return (
    <div>
      {state === "loading" && <p className="muted small">Loading indicators…</p>}
      {state === "error" && <p style={{ color: T.red }}>Could not load indicators.</p>}
      <Title rule="MACD line above signal">Monthly MACD</Title>
      <div ref={macdBox} style={frame} />
      <Title rule="MACD line above signal">Daily MACD</Title>
      <div ref={macdDBox} style={frame} />
      <Title rule="above 40 (red line)">{tf} RSI (14)</Title>
      <div ref={rsiBox} style={frame} />
      <Title rule="%K crosses up through %D from below 20 (▲)">{tf} Stochastic (14, 3, 3)</Title>
      <div ref={stBox} style={frame} />
    </div>
  );
}
