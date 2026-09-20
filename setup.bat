@echo off
REM ============================================================
REM  Contextual Banner Alert - one-click project setup
REM  Double-click this file. It calls setup.ps1 in the same folder.
REM ============================================================

echo.
echo ============================================================
echo   Contextual Banner Alert - project setup
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"

echo.
echo ============================================================
echo   Finished. Read the messages above.
echo ============================================================
echo.
pause
