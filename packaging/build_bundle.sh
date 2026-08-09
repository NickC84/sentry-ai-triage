#!/usr/bin/env bash
# Assemble a self-contained release bundle: native binaries + prebuilt web UI
# + default rules. Whoever unzips it needs neither Dart nor Flutter.
#
#   packaging/build_bundle.sh --out dist/sentry-ai-triage-macos-arm64
#   packaging/build_bundle.sh --out dist/... --web /path/to/prebuilt/web
#
# --web takes an already-built Flutter web directory (CI builds it once on
# Linux and reuses it for every platform); without it, Flutter runs here.
set -euo pipefail

out=""
web=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --web) web="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$out" ] || { echo "--out is required" >&2; exit 2; }

cd "$(dirname "$0")/.."
repo="$(pwd)"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) exe=".exe" ;;
  *) exe="" ;;
esac

echo "▶ dependencies"
dart pub get

if [ -z "$web" ]; then
  echo "▶ building the web UI"
  ( cd ui && flutter pub get && flutter build web --no-web-resources-cdn )
  web="$repo/ui/build/web"
fi
[ -f "$web/index.html" ] || { echo "no web build at $web" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

echo "▶ compiling binaries"
compile() { # <entry point> <output name>
  dart compile exe "bin/$1.dart" -o "$out/$2$exe" --verbosity=warning
}
compile serve   sentry-triage
compile ingest  sentry-triage-ingest
compile analyze sentry-triage-analyze
compile feature sentry-triage-feature

echo "▶ staging assets"
cp -R "$web" "$out/web"
mkdir -p "$out/rules"
cp rules/default_rules.json "$out/rules/"
cp README.md LICENSE .env.example "$out/"

# One launcher per platform — the binary runs fine on its own, but a
# double-clickable entry point is what most people expect from a zip.
#
# The native SQLite library is picked up from the repo root when present
# (CI stages it there): Windows has no system SQLite at all, and minimal
# Linux images may lack one. macOS always has it.
case "$(uname -s)" in
  Darwin)
    cp packaging/start.command "$out/"; chmod +x "$out/start.command"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    cp packaging/start.bat "$out/"
    [ -f sqlite3.dll ] && cp sqlite3.dll "$out/" || echo "⚠️  no sqlite3.dll staged — the bundle will need one on PATH"
    ;;
  *)
    cp packaging/start.sh "$out/"; chmod +x "$out/start.sh"
    [ -f libsqlite3.so.0 ] && cp libsqlite3.so.0 "$out/" || true
    ;;
esac

echo "✅ bundle ready: $out"
ls -la "$out"
