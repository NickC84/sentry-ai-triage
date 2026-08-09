@echo off
rem Launcher for a source checkout - needs Dart, and Flutter for the first
rem build. Not the recommended path for users: the GitHub release zips contain
rem prebuilt binaries and web assets and need neither.
rem   start.bat             normal start
rem   start.bat --rebuild   force-rebuild the web UI
cd /d "%~dp0"

echo ^> Sentry AI Triage

where dart >nul 2>nul
if errorlevel 1 (
  echo [x] Dart SDK not found. Install it first: https://dart.dev/get-dart
  pause
  exit /b 1
)

call dart pub get >nul 2>nul

if "%~1"=="--rebuild" goto build
if not exist "ui\build\web\index.html" goto build
goto run

:build
where flutter >nul 2>nul
if errorlevel 1 (
  echo [x] Flutter not found - it's needed once to build the web UI.
  echo     Install it ^(https://flutter.dev^), then re-run this script - or
  echo     grab a release zip, which already contains the built UI:
  echo     https://github.com/NickC84/sentry-ai-triage/releases
  pause
  exit /b 1
)
echo [build] Building the web UI (first run only, takes a minute)...
pushd ui
call flutter pub get
call flutter build web --no-web-resources-cdn
popd

:run
echo [run] Starting... your browser will open http://localhost:8787
echo       First time? Open Settings in the UI and fill in your Sentry info.
echo       (stop with Ctrl-C in this window)
dart run bin/serve.dart %*
