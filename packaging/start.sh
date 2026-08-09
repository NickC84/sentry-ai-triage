#!/usr/bin/env bash
# Linux: ./start.sh   (or run ./sentry-triage directly)
set -e
cd "$(dirname "$0")"
exec ./sentry-triage "$@"
