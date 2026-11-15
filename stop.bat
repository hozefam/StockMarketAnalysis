@echo off
rem Stops the backend (port 8000) and frontend (port 3000) started by start.bat.
setlocal

for %%P in (8000 3000) do (
  for /f "tokens=5" %%I in ('netstat -ano ^| findstr ":%%P " ^| findstr LISTENING') do (
    echo Stopping process %%I on port %%P
    taskkill /F /T /PID %%I >nul 2>&1
  )
)

rem close the two console windows too
taskkill /F /T /FI "WINDOWTITLE eq StockMarket Backend*" >nul 2>&1
taskkill /F /T /FI "WINDOWTITLE eq StockMarket Frontend*" >nul 2>&1

echo Done.
endlocal
