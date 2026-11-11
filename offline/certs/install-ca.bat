@echo off
rem ============================================================================
rem  Buzz offline relay - install the private CA root certificate (Windows)
rem ============================================================================
rem  Run this file ONCE per Windows client PC, as Administrator:
rem     right-click install-ca.bat  ->  "Run as administrator"
rem  (or:  certutil -addstore -f Root "%~dp0ca.crt"   in an admin cmd)
rem
rem  It installs ca.crt from the folder this .bat lives in into the
rem  "Trusted Root Certification Authorities" store of the LOCAL MACHINE.
rem  After that, the Buzz desktop app can open  wss://<server>:<port>  without
rem  a certificate warning, because its TLS stack uses the OS root store.
rem
rem  ca.crt must sit next to this file. It is issued on the SERVER by:
rem     sudo ./scripts/make-ca.sh --host <server-ip> --port 40009
rem  and copied to each client (it is a PUBLIC certificate - safe to share; only
rem  ca.key is secret and never leaves the server).
rem ============================================================================
setlocal

set "CA=%~dp0ca.crt"

if not exist "%CA%" (
  echo ERROR: ca.crt not found next to this script.
  echo        Put ca.crt in the same folder as install-ca.bat and retry.
  pause
  exit /b 1
)

rem Require elevation: writing to the machine store needs Administrator.
net session >nul 2>&1
if errorlevel 1 (
  echo ERROR: this script must run as Administrator.
  echo        Right-click install-ca.bat and choose "Run as administrator".
  pause
  exit /b 1
)

echo Installing "%CA%" into Trusted Root Certification Authorities ...
certutil -addstore -f Root "%CA%"
if errorlevel 1 (
  echo ERROR: certutil failed to add the certificate.
  pause
  exit /b 1
)

echo.
echo OK - the Buzz Offline Relay CA is now trusted on this PC.
echo You can now add the community  wss://^<server^>:^<port^>  in the Buzz desktop app.
echo.
rem Show the entry so it can be removed later if ever needed:
certutil -store Root | findstr /i "Buzz Offline Relay CA"
pause
exit /b 0
