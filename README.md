# StockMarketAnalysis

A FastAPI backend and Next.js frontend that connects to the Groww API and scans the Nifty 50 with a Dow-theory
approach: trend on monthly / weekly / daily charts, 61.8% weekly pullbacks, EMA 20/50/100 confirmation, and
MACD / RSI / stochastic momentum rules, scored and ranked.

> A screening aid built on pattern rules. It is not investment advice and has not been backtested.

## Setup

### 1. Secrets
Copy the example and fill in your Groww TOTP token and secret. `key.txt` is git-ignored, so don't commit it.

```bash
cp backend/key.txt.example backend/key.txt
```

### 2. Backend (port 8000)
```bash
cd backend
python -m venv .venv
.venv/Scripts/pip install -r requirements.txt     # Windows; use .venv/bin/pip on macOS/Linux
.venv/Scripts/python -m uvicorn main:app --port 8000
```

### 3. Frontend (port 3000)
```bash
cd frontend
npm install
npm run dev
```

Open http://localhost:3000 (home) and http://localhost:3000/analysis (scanner).

## Notes
- Price history comes from Yahoo Finance; the Groww key used here has no market-data access.
- Momentum timeframe for RSI and stochastic is set by `MOMENTUM_TF` in `backend/dow.py` (`"1d"` or `"1wk"`).
