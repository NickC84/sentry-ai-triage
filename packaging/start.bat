@echo off
rem Windows: double-click to launch Sentry AI Triage.
cd /d "%~dp0"
sentry-triage.exe %*
echo.
echo (server stopped)
pause
