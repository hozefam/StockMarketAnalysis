import os
from pathlib import Path

import httpx
import pyotp
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

GROWW_BASE = "https://api.groww.in/v1"
KEY_FILE = Path(__file__).parent / "key.txt"
SECRET_NAMES = ("GROWW_TOTP_TOKEN", "GROWW_TOTP_SECRET")

app = FastAPI(title="StockMarket Backend")
# In Azure the browser never calls this service directly (the frontend proxies to it), so CORS only matters locally.
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.environ.get("CORS_ORIGINS", "http://localhost:3000").split(","),
    allow_methods=["GET"],
    allow_headers=["*"],
)


def load_keys() -> dict:
    """Secrets come from environment variables (Azure Key Vault -> Container Apps secrets),
    falling back to backend/key.txt for local development."""
    env = {k: os.environ[k] for k in SECRET_NAMES if os.environ.get(k)}
    if len(env) == len(SECRET_NAMES):
        return env
    keys = {}
    for line in KEY_FILE.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            keys[k.strip()] = v.strip()
    return keys


@app.get("/")
def root():
    return {"message": "FastAPI backend is running"}


@app.get("/api/groww/status")
def groww_status():
    """Exchange the TOTP token + secret for a Groww access token to prove connectivity."""
    try:
        keys = load_keys()
        totp = pyotp.TOTP(keys["GROWW_TOTP_SECRET"]).now()
        resp = httpx.post(
            f"{GROWW_BASE}/token/api/access",
            headers={
                "Authorization": f"Bearer {keys['GROWW_TOTP_TOKEN']}",
                "Accept": "application/json",
            },
            json={"key_type": "totp", "totp": totp},
            timeout=15,
        )
    except Exception as e:  # missing key file, network error, etc.
        return {"connected": False, "message": f"Could not reach Groww: {e}"}

    if resp.status_code == 200 and resp.json().get("token"):
        return {"connected": True, "message": "Successfully established connection with the Groww backend."}
    return {
        "connected": False,
        "message": f"Groww rejected the request (HTTP {resp.status_code}).",
        "detail": resp.text[:300],
    }


# ---------- Authenticated Groww data (read-only) ----------
import time

_token_cache = {"token": None, "at": 0.0}


def get_access_token() -> str:
    # Access tokens are long-lived enough to cache for a while
    if _token_cache["token"] and time.time() - _token_cache["at"] < 1800:
        return _token_cache["token"]
    keys = load_keys()
    totp = pyotp.TOTP(keys["GROWW_TOTP_SECRET"]).now()
    resp = httpx.post(
        f"{GROWW_BASE}/token/api/access",
        headers={"Authorization": f"Bearer {keys['GROWW_TOTP_TOKEN']}", "Accept": "application/json"},
        json={"key_type": "totp", "totp": totp},
        timeout=15,
    )
    resp.raise_for_status()
    _token_cache.update(token=resp.json()["token"], at=time.time())
    return _token_cache["token"]


def groww_get(path: str, params: dict | None = None):
    try:
        resp = httpx.get(
            f"{GROWW_BASE}{path}",
            params=params,
            headers={
                "Authorization": f"Bearer {get_access_token()}",
                "Accept": "application/json",
                "X-API-VERSION": "1.0",
            },
            timeout=15,
        )
        body = resp.json() if resp.content else {}
        if resp.status_code != 200:
            return {"ok": False, "status": resp.status_code, "error": body}
        return {"ok": True, "data": body.get("payload", body)}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.get("/api/groww/margin")
def margin():
    return groww_get("/margins/detail/user")


@app.get("/api/groww/holdings")
def holdings():
    return groww_get("/holdings/user")


@app.get("/api/groww/quote")
def quote(symbol: str = "RELIANCE", exchange: str = "NSE", segment: str = "CASH"):
    return groww_get(
        "/live-data/quote",
        {"exchange": exchange, "segment": segment, "trading_symbol": symbol.upper()},
    )


# ---------- Dow theory / Fibonacci analysis ----------
from concurrent.futures import ThreadPoolExecutor

import dow

_dow_cache = {"at": 0.0, "data": None}


def _safe_analyse(sym: str):
    try:
        return dow.analyse(sym)
    except Exception as e:
        return {"symbol": sym, "error": str(e)[:120], "retracements": []}


@app.get("/api/analysis/dow")
def dow_analysis(refresh: bool = False):
    if not refresh and _dow_cache["data"] and time.time() - _dow_cache["at"] < 3600:
        return _dow_cache["data"]
    with ThreadPoolExecutor(8) as ex:
        results = list(ex.map(_safe_analyse, ["NIFTY50"] + dow.NIFTY50))
    data = {"results": results, "band": [dow.LOW, dow.HIGH]}
    _dow_cache.update(at=time.time(), data=data)
    return data


@app.get("/api/analysis/candles")
def candles(symbol: str, interval: str = "1wk"):
    try:
        return {"ok": True, **dow.candles(symbol, interval)}
    except Exception as e:
        return {"ok": False, "error": str(e)[:120]}


@app.get("/api/analysis/indicators")
def indicators(symbol: str):
    try:
        return {"ok": True, **dow.indicators(symbol)}
    except Exception as e:
        return {"ok": False, "error": str(e)[:120]}
