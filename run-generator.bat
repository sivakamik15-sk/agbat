@echo off
REM Generates the bulk test rule files on the Desktop. Does NOT deploy.
REM Put policies.csv and content.csv next to this file first.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate-bulk-test-files.ps1"
echo.
pause
