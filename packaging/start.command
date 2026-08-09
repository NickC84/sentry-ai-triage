#!/bin/bash
# macOS: double-click in Finder to launch Sentry AI Triage.
cd "$(dirname "$0")"

# Anything downloaded from a browser carries a quarantine flag, and Gatekeeper
# refuses to run unsigned binaries that have it. Clearing it on our own folder
# is what the manual `xattr -dr com.apple.quarantine .` in the README does.
xattr -dr com.apple.quarantine . 2>/dev/null || true

exec ./sentry-triage "$@"
