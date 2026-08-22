@echo off
REM ============================================================================
REM  chrome-debug-test.bat  -  start Chrome with a debug port, ONCE, for a test.
REM
REM  WHY THIS EXISTS: the flag only takes effect on a COLD start. If any Chrome
REM  window is already open, Windows hands the URL to the running instance and
REM  silently ignores --remote-debugging-port - so the test appears to fail for
REM  a reason that has nothing to do with what is being tested. This checks
REM  first and refuses to launch until Chrome is really closed.
REM
REM  *** READ THIS BEFORE USING IT ***
REM  A debug port lets ANY program on this PC drive this browser: read cookies,
REM  act as you on every site you are signed in to, with no prompt. It is
REM  local-only (not reachable from the internet), but it is a real widening of
REM  what a bad program on this machine could do.
REM  This is intended as a SHORT TEST. Close this Chrome window when the test is
REM  done and go back to opening Chrome normally.
REM ============================================================================
setlocal
set CHROME=C:\Program Files\Google\Chrome\Application\chrome.exe
if not exist "%CHROME%" set CHROME=C:\Program Files (x86)\Google\Chrome\Application\chrome.exe
title Chrome debug-port test

cls
echo.
echo   ===========================================================
echo     START CHROME WITH A DEBUG PORT  (one-off test)
echo   ===========================================================
echo.
echo   This lets Claude attach to YOUR real Chrome - your profile,
echo   your logins, your extensions - to test whether Walmart
echo   answers it normally.
echo.
echo   SECURITY: while this window's Chrome is open, any program on
echo   this PC could drive your browser. Local only, but real.
echo   Close that Chrome when the test is finished.
echo.

:checkclosed
tasklist /FI "IMAGENAME eq chrome.exe" 2>NUL | find /I "chrome.exe" >NUL
if errorlevel 1 goto launch
echo   Chrome is still running - the flag is IGNORED unless Chrome
echo   is fully closed first.
echo.
echo   Please close ALL Chrome windows now, then press any key.
echo   (Your tabs will reopen when Chrome restarts.)
echo.
pause >NUL
goto checkclosed

:launch
echo.
echo   Chrome is closed. Starting it with the debug port...
start "" "%CHROME%" --remote-debugging-port=9222
echo.
echo   Done. Chrome should be opening now.
echo   Tell Claude it is up, and it will run ONE Walmart check.
echo.
pause
