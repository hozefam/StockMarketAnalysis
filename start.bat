@echo off
rem Starts the FastAPI backend (port 8000) and Next.js frontend (port 3000) in two windows.
rem Usage: start.bat            (opens the browser when ready)
rem        start.bat nobrowser  (skip opening the browser)
setlocal
cd /d "%~dp0"

if not exist "backend\key.txt" (
  echo [!] backend\key.txt is missing.
  echo     Copy backend\key.txt.example to backend\key.txt and fill in your Groww token and secret.
  pause
  exit /b 1
)

if not exist "backend\.venv\Scripts\python.exe" (
  echo [setup] Creating Python virtual environment and installing backend dependencies...
  python -m venv backend\.venv || (echo [!] Python not found. Install Python 3 first. & pause & exit /b 1)
  backend\.venv\Scripts\python.exe -m pip install -q -r backend\requirements.txt
)

if not exist "frontend\node_modules" (
  echo [setup] Installing frontend dependencies...
  pushd frontend
  call npm.cmd install || (echo [!] npm install failed. Is Node.js installed? & popd & pause & exit /b 1)
  popd
)

echo Starting backend  on http://localhost:8000
start "StockMarket Backend" cmd /k "cd /d "%~dp0backend" && .venv\Scripts\python.exe -m uvicorn main:app --reload --port 8000"

echo Starting frontend on http://localhost:3000
start "StockMarket Frontend" cmd /k "cd /d "%~dp0frontend" && npm.cmd run dev"

if /i not "%~1"=="nobrowser" (
  rem give the servers a few seconds, then open the app
  ping -n 8 127.0.0.1 >nul
  start "" http://localhost:3000
)

echo.
echo Both servers are starting in their own windows. Run stop.bat to shut them down.
endlocal
