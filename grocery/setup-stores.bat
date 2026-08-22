@echo off
REM ============================================================================
REM  Seed Store Profiles.bat
REM
REM  Double-clickable front door for pull-browser-stores.py --seed.
REM
REM  WHY THIS EXISTS: the seeding step is a one-time job a PERSON does, and the
REM  only way to start it was a full command line with two absolute paths in it.
REM  Brad's answer to that, 2026-08-22, was "IDK how to do this?" - which is the
REM  correct response to being handed a command line for a once-a-quarter task.
REM  A tool a person cannot start is a tool that does not run.
REM
REM  The window is deliberately kept open at every exit (pause), because the
REM  whole point of seeding is READING what the store verification said.
REM ============================================================================
setlocal
set PY=C:\Codex\Python312\python.exe
set DRIVER=C:\Codex\ThriftyCrew\grocery\pull-browser-stores.py
title Thrifty Crew - Seed Store Profiles

if not exist "%PY%" (
  echo.
  echo   Cannot find Python at:
  echo     %PY%
  echo   Nothing will work until that path is right. Tell Claude what this says.
  echo.
  pause
  exit /b 1
)
if not exist "%DRIVER%" (
  echo.
  echo   Cannot find the driver at:
  echo     %DRIVER%
  echo   Tell Claude what this says.
  echo.
  pause
  exit /b 1
)

:menu
cls
echo.
echo   ===========================================================
echo     THRIFTY CREW  -  SET UP THE GROCERY STORE PROFILES
echo   ===========================================================
echo.
echo   You only do this ONCE per store. After that the 8am job
echo   captures prices on its own.
echo.
echo   A Chrome window will open. Pick the Omaha store in it.
echo   It saves BY ITSELF once the page proves the right store.
echo   Do not type anything in this black window.
echo.
echo     1  -  Fareway      (start here - easiest)
echo     2  -  Walmart
echo     3  -  Sam's Club   (you will need to sign in)
echo.
echo     4  -  CHECK: are the stores working?
echo.
echo     5  -  Quit
echo.
REM `choice` rather than `set /p`: it takes a single keypress, cannot return an
REM empty or whitespace-padded value, and cannot pick up a stray carriage return
REM (which is what turned `if "%choice%"=="1"` into a syntax error when this was
REM first tested). One less thing for a person to get wrong, too - no Enter.
choice /c 12345 /n /m "  Press a number (1-5): "
if errorlevel 5 exit /b 0
if errorlevel 4 goto check
if errorlevel 3 goto sams
if errorlevel 2 goto walmart
if errorlevel 1 goto fareway
goto menu

:fareway
cls
echo.
echo   FAREWAY
echo   -------
echo   When Chrome opens:
echo     1. Click the store name at the top of the page.
echo     2. Choose "Change store".
echo     3. Search for   68136
echo     4. Pick  17070 Audrey Street, Omaha
echo     5. Make sure the header says IN-STORE (not Delivery or Pickup).
echo.
echo   Below you will see REFUSED lines every few seconds. That is
echo   normal - it is telling you it does not see Omaha yet. When it
echo   does, it saves and closes on its own.
echo.
"%PY%" "%DRIVER%" --store fareway --seed
goto done

:walmart
cls
echo.
echo   WALMART
echo   -------
echo   When Chrome opens:
echo     1. Set the pickup store to an Omaha store
echo        (Omaha L St Supercenter, 12850 L ST, 68137).
echo     2. Click around two or three pages so the browser looks
echo        like a normal shopper rather than a brand new one.
echo.
echo   This one saves after about 20 seconds either way - Walmart
echo   gives us no way to prove which store we are on.
echo.
"%PY%" "%DRIVER%" --store walmart --seed
goto done

:sams
cls
echo.
echo   SAM'S CLUB
echo   ----------
echo   When Chrome opens:
echo     1. Sign in with your membership.
echo     2. Set the club to   15429 Blackwell Dr
echo.
echo   *** GET THE CLUB RIGHT ***
echo   Some old notes say 13130 L St. That is the WRONG one now.
echo   Sam's prices differ per club, and picking the wrong Omaha
echo   club would look completely fine while quietly changing
echo   every Sam's price on the board.
echo.
"%PY%" "%DRIVER%" --store samsclub --seed
goto done

:check
cls
echo.
echo   CHECKING ALL THREE STORES
echo   -------------------------
echo   Each store should say it WROTE a capture file.
echo   If one says NEEDS SEEDING, run that store's option above.
echo.
"%PY%" "%DRIVER%"
goto done

:done
echo.
echo   ===========================================================
echo   Finished. Read the lines above.
echo     "profile seeded"  = that store is set up.
echo     "NEEDS SEEDING"   = not set up yet, try it again.
echo   ===========================================================
echo.
pause
goto menu
