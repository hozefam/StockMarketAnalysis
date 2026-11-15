// Shared colours for the chart panes (match globals.css)
export const T = {
  panel: "#121a2f",
  border: "#243050",
  muted: "#8a96b2",
  grid: "#1a2442",
  green: "#22c55e",
  red: "#f43f5e",
  amber: "#f59e0b",
  accent: "#7c5cff",
  cyan: "#22d3ee",
  ema: { 20: "#38bdf8", 50: "#c084fc", 100: "#f8fafc" },
};

export const chartOptions = (height) => ({
  height,
  layout: { background: { color: T.panel }, textColor: T.muted, fontSize: 11 },
  grid: { vertLines: { color: T.grid }, horzLines: { color: T.grid } },
  rightPriceScale: { borderColor: T.border },
  timeScale: { borderColor: T.border },
  crosshair: { mode: 0 },
});
