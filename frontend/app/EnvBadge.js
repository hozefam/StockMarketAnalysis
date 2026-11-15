"use client";
import { useEffect, useState } from "react";

const COLORS = { dev: "#22d3ee", qa: "#a78bfa", uat: "#f59e0b" };

// A small tab in the corner for every environment except prod (and local development).
export default function EnvBadge() {
  const [env, setEnv] = useState(null);

  useEffect(() => {
    fetch("/api/env")
      .then((r) => r.json())
      .then((d) => setEnv(d.env))
      .catch(() => {});
  }, []);

  if (!env || env === "prod" || env === "local") return null;
  return (
    <div
      style={{
        position: "fixed", top: 0, right: 16, zIndex: 50, padding: "3px 12px",
        borderRadius: "0 0 8px 8px", fontSize: 12, fontWeight: 800, letterSpacing: "0.08em",
        background: COLORS[env] || "#94a3b8", color: "#0b1020",
      }}
    >
      {env.toUpperCase()}
    </div>
  );
}
