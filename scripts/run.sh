#!/bin/sh
# Builds and runs Caton from the terminal. CATON_DRY_RUN=1 keeps every change
# local; CATON_GITHUB_TOKEN=$(gh auth token) skips the sign-in screen.
set -e
cd "$(dirname "$0")/.."
swift build
# Only the debug build: the installed app is a process named Caton too.
pkill -f "\.build/debug/Caton" 2>/dev/null || true
exec .build/debug/Caton
