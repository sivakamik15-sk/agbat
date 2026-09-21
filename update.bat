@echo off
REM ============================================================
REM  Contextual Banner Alert - update config and component
REM
REM  Rewrites the two JSON config files with your test rules,
REM  refreshes the LWC with the latest code, and optionally
REM  deploys both.
REM
REM  EDIT THE SETTINGS AT THE TOP OF update.ps1 FIRST.
REM  Then double-click this file.
REM ============================================================

echo.
echo ============================================================
echo   Contextual Banner Alert - update
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1"

echo.
echo ============================================================
echo   Finished. Read the messages above.
echo ============================================================
echo.
pause
