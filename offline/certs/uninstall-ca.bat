@echo off
rem ============================================================================
rem  Buzz offline relay - REMOVE the private CA root certificate (Windows)
rem ============================================================================
rem  Run as Administrator. Deletes the "Buzz Offline Relay CA" entry from the
rem  machine Trusted Root store, so wss:// connections to this relay will again
rem  fail certificate validation. Only needed when decommissioning the relay.
rem ============================================================================
setlocal

net session >nul 2>&1
if errorlevel 1 (
  echo ERROR: run as Administrator (right-click -> "Run as administrator").
  pause
  exit /b 1
)

for /f "delims=" %%s in ('certutil -store Root "Buzz Offline Relay CA" ^| findstr /i /c:"Serial Number"') do (
  for /f "tokens=2 delims=: " %%n in ("%%s") do set "SERIAL=%%n"
)
if not defined SERIAL (
  echo No "Buzz Offline Relay CA" certificate found in the Root store.
  pause
  exit /b 0
)

echo Removing CA serial %SERIAL% from Trusted Root Certification Authorities ...
certutil -delstore Root %SERIAL%
if errorlevel 1 (
  echo ERROR: certutil -delstore failed.
  pause
  exit /b 1
)
echo OK - CA removed. Relaunch the Buzz app to pick up the change.
pause
exit /b 0
