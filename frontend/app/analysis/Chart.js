"use client";
import { useEffect, useRef, useState } from "react";
import { createChart, LineStyle } from "lightweight-charts";
import { T, chartOptions } from "./theme";

// 61.8% level of a leg, measured back from the leg's end toward its start
const level = (x) => x.leg_end.price - 0.618 * (x.leg_end.price - x.leg_start.price);

export default function Chart({ symbol, retracements }) {
  const box = useRef(null);
  const [state, setState] = useState("loading");
  const [tf, setTf] = useState("1wk");

  useEffect(() => {
    let chart, dead = false;
    setState("loading");
    fetch(`http://localhost:8000/api/analysis/candles?symbol=${encodeURIComponent(symbol)}&interval=${tf}`)
      .then((r) => r.json())
      .then((d) => {
        if (dead) return;
        if (!d.ok) return setState("error");
        setState("ready");

        chart = createChart(box.current, chartOptions(420));
        const candles = chart.addCandlestickSeries({
          upColor: T.green, downColor: T.red,
          borderUpColor: T.green, borderDownColor: T.red,
          wickUpColor: T.green, wickDownColor: T.red,
        });
        candles.setData(d.candles);
        const times = d.candles.map((c) => c.time);
        const last = times[times.length - 1];
        const snap = (t) => times.find((x) => x >= t) || last;
        const barOf = (t) => (tf === "1d" ? snap(t) : [...times].reverse().find((x) => x <= t) || times[0]);
        const markers = [];

        // Daily EMA lines on both views (weekly view samples the daily EMA at each weekly date)
        const sampleAt = (data, t) => data.find((p) => p.time >= t);
        Object.entries(d.emas).forEach(([n, data]) => {
          const pts = tf === "1d"
            ? data
            : times.map((t) => { const p = sampleAt(data, t); return p && { time: t, value: p.value }; }).filter(Boolean);
          chart.addLineSeries({
            color: T.ema[n], lineWidth: 2, lastValueVisible: true, priceLineVisible: false, title: `EMA${n}`,
          }).setData(pts);
        });

        // confirmed crossovers (price above all 3 EMAs while stacked 20>50>100)
        const strictSet = new Set(d.strict_crossovers);
        d.strict_crossovers.forEach((t) =>
          markers.push({ time: barOf(t), position: "belowBar", shape: "circle", color: T.green, text: "✔" })
        );
        if (tf === "1d") {
          d.crossovers.filter((t) => !strictSet.has(t)).forEach((t) =>
            markers.push({ time: t, position: "belowBar", shape: "circle", color: T.amber, text: "x" })
          );
          d.ema_events.forEach((e) =>
            markers.push({
              time: e.time, position: "aboveBar", shape: "square",
              color: e.type === "20/50" ? T.ema[20] : T.ema[50],
              text: e.type === "20/50" ? "20↑50" : "50↑100",
            })
          );
        }

        // Dow swing structure on the weekly view: zig-zag + HH / HL / LH / LL labels
        if (tf === "1wk" && d.pivots?.length) {
          chart.addLineSeries({ color: "#4b5a82", lineWidth: 1, lastValueVisible: false, priceLineVisible: false })
            .setData(d.pivots.map((p) => ({ time: p.time, value: p.price })));
          d.pivots.forEach((p) =>
            markers.push({
              time: p.time, position: p.type === "H" ? "aboveBar" : "belowBar", shape: "circle",
              color: p.label === "HH" || p.label === "HL" ? "#4ade80" : p.label === "H" || p.label === "L" ? "#94a3b8" : "#fb7185",
              text: p.label,
            })
          );
        }

        // the 61.8% retracements themselves
        retracements.forEach((x) => {
          const t0 = (t) => (tf === "1d" ? snap(t) : t);
          chart.addLineSeries({ color: "#94a3b8", lineWidth: 2, lineStyle: LineStyle.Dashed, lastValueVisible: false, priceLineVisible: false })
            .setData([{ time: t0(x.leg_start.date), value: x.leg_start.price }, { time: t0(x.leg_end.date), value: x.leg_end.price }]);
          chart.addLineSeries({ color: T.amber, lineWidth: 2, lastValueVisible: false, priceLineVisible: false })
            .setData([{ time: t0(x.leg_end.date), value: level(x) }, { time: t0(x.date), value: level(x) }]);
          const up = x.direction.startsWith("pullback");
          markers.push({
            time: t0(x.date), position: up ? "belowBar" : "aboveBar", shape: up ? "arrowUp" : "arrowDown",
            color: up ? T.green : T.red, text: `${(x.ratio * 100).toFixed(1)}%`,
          });
        });

        markers.sort((a, b) => (a.time < b.time ? -1 : a.time > b.time ? 1 : 0));
        const seen = new Set();
        for (let i = markers.length - 1; i >= 0; i--) {
          const k = markers[i].time + markers[i].text;
          if (seen.has(k)) markers.splice(i, 1); else seen.add(k);
        }
        candles.setMarkers(markers);
        chart.timeScale().setVisibleRange({
          from: new Date(Date.parse(last) - (tf === "1d" ? 400 : 450) * 864e5).toISOString().slice(0, 10),
          to: last,
        });
      })
      .catch(() => !dead && setState("error"));
    return () => { dead = true; chart && chart.remove(); };
  }, [symbol, retracements, tf]);

  return (
    <div>
      <div className="seg" style={{ marginBottom: 12 }}>
        <button className={tf === "1wk" ? "on" : ""} onClick={() => setTf("1wk")}>Weekly</button>
        <button className={tf === "1d" ? "on" : ""} onClick={() => setTf("1d")}>Daily</button>
      </div>
      {state === "loading" && <p className="muted small">Loading chart…</p>}
      {state === "error" && <p style={{ color: T.red }}>Could not load price data.</p>}
      <div ref={box} style={{ borderRadius: 12, overflow: "hidden" }} />
      <div className="legend">
        <span><i style={{ background: "#94a3b8" }} />swing leg retraced</span>
        <span><i style={{ background: T.amber }} />61.8% level</span>
        <span style={{ color: T.green }}>▲ dip in up-leg</span>
        <span style={{ color: T.red }}>▼ bounce in down-leg</span>
        <span style={{ color: T.green }}>● ✔ confirmed EMA cross</span>
        <span><i style={{ background: T.ema[20] }} />EMA 20</span>
        <span><i style={{ background: T.ema[50] }} />EMA 50</span>
        <span><i style={{ background: T.ema[100] }} />EMA 100</span>
        {tf === "1wk" && <span>HH/HL <b style={{ color: "#4ade80" }}>green</b> · LH/LL <b style={{ color: "#fb7185" }}>red</b></span>}
        {tf === "1d" && <span style={{ color: T.amber }}>● x price-only cross</span>}
      </div>
    </div>
  );
}
