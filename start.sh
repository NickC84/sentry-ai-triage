#!/usr/bin/env bash
# Launcher for a source checkout — needs Dart, and Flutter for the first
# build. Not the recommended path for users: the GitHub release zips contain
# prebuilt binaries and web assets and need neither.
#   ./start.sh              normal start
#   ./start.sh --rebuild    force-rebuild the web UI
#   ./start.sh --port 9000  custom port
set -e
cd "$(dirname "$0")"

echo "▶ Sentry AI Triage"

if ! command -v dart >/dev/null 2>&1; then
  echo "❌ Dart SDK not found. Install it first: https://dart.dev/get-dart"
  echo "   (press any key to close)"; read -n 1 -s; exit 1
fi

# Backend dependencies (quiet when already up to date).
dart pub get >/dev/null 2>&1 || dart pub get

# Build the web UI on first run (or with --rebuild).
rebuild=""
if [ "${1:-}" = "--rebuild" ]; then rebuild=1; shift; fi
if [ -n "$rebuild" ] || [ ! -f ui/build/web/index.html ]; then
  if ! command -v flutter >/dev/null 2>&1; then
    echo "❌ Flutter not found — it's needed once to build the web UI."
    echo "   Install it (https://flutter.dev), then re-run this script —"
    echo "   or grab a release zip, which already contains the built UI:"
    echo "   https://github.com/NickC84/sentry-ai-triage/releases"
    echo "   (press any key to close)"; read -n 1 -s; exit 1
  fi
  echo "🧱 Building the web UI (first run only, takes a minute)…"
  ( cd ui && flutter pub get && flutter build web --no-web-resources-cdn )
fi

# Start the server — it opens the browser itself (disable with NO_OPEN=1).
echo "🚀 Starting… your browser will open http://localhost:${PORT:-8787}"
echo "   First time? Open Settings in the UI and fill in your Sentry info."
echo "   (stop with Ctrl-C in this window)"
exec dart run bin/serve.dart "$@"
