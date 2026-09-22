@echo off
REM ============================================================
REM  Contextual Banner Alert - write config files ONLY
REM
REM  Rewrites PolicyBannerConfig.json and ContactBannerConfig.json
REM  from the settings in write-config.ps1.
REM
REM  IT DOES NOT DEPLOY. You run the deploy command yourself.
REM
REM  1. Edit the SETTINGS block in write-config.ps1
REM  2. Save it
REM  3. Double-click this file
REM  4. Run the deploy command it prints
REM ============================================================

echo.
echo ============================================================
echo   Writing config files  (no deployment)
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0write-config.ps1"

echo.
echo ============================================================
echo   Finished. Read the messages above.
echo ============================================================
echo.
pause
