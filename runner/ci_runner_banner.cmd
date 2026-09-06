@echo off
rem CI runner wrapper: give that blank console window something to say.
rem
rem ## Why this exists
rem
rem The scheduled task used to run cmd /c "run.cmd >> log 2>&1" directly. Every
rem line of output goes to the log, so the desktop got a completely blank CMD
rem window. On 2026-08-31 the user asked what it was. A window that cannot say
rem what it is invites being closed -- and closing it kills CI.
rem
rem ## Why this file is pure ASCII
rem
rem First attempt put the Chinese banner straight into this .cmd. It broke badly:
rem cmd parses a batch file line by line in the *current* code page (cp950 here),
rem and UTF-8 Chinese bytes shift that double-byte parse -- rem lines got executed
rem as commands and one echo was split in half.
rem
rem So the parser never sees non-ASCII. The Chinese lives in banner.txt and is
rem dumped with `type`, which just copies bytes to the console.
rem
rem ## Why the code page is restored
rem
rem chcp 65001 is needed for the UTF-8 banner, but it must not be left in place
rem for run.cmd: the runner writes to run-detached.log, and changing the code page
rem changes that log encoding -- and that log is the only clue when CI breaks.
rem
rem ## Why there is no pause at the end
rem
rem A leftover "press any key" window would make the status light lie: it looks
rem lit while CI is already down. Window present = alive, window gone = dead.

setlocal enabledelayedexpansion

set "RUNNER_DIR=C:\actions-runner"
set "BANNER=%~dp0ci_runner_banner.txt"

rem chcp output differs by locale ("Active code page: 950." / a localized string),
rem so take what follows the colon and strip spaces and the trailing period.
for /f "tokens=2 delims=:" %%c in ('chcp') do set "ORIGINAL_CP=%%c"
set "ORIGINAL_CP=!ORIGINAL_CP: =!"
set "ORIGINAL_CP=!ORIGINAL_CP:.=!"
if "!ORIGINAL_CP!"=="" set "ORIGINAL_CP=950"

title CI Runner - running - DO NOT CLOSE (closing this window stops CI)
chcp 65001 >nul
cls
if exist "%BANNER%" (type "%BANNER%") else (echo [banner file missing: %BANNER%])
echo.
echo    started %DATE% %TIME%
echo.
chcp !ORIGINAL_CP! >nul

cd /d "%RUNNER_DIR%"
run.cmd >> "%RUNNER_DIR%\_diag\run-detached.log" 2>&1
