#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 Scripts/localize.py
swift test --scratch-path "$HOME/Library/Caches/HaHaTranslateDevelopment/SwiftBuildTests"
