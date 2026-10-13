#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${HAHA_BUILD_CACHE:-$HOME/Library/Caches/HaHaTranslateDevelopment/runtime}"
LIBRARY="$ROOT/Runtime/CHaHaRuntime.xcframework/macos-arm64/libCHaHaRuntime.a"
if [[ $# -lt 1 ]]; then echo 'Supply one or more verified Hy-MT2 GGUF model paths.' >&2; exit 64; fi
mkdir -p "$CACHE"
if [[ ! -f "$LIBRARY" ]]; then "$ROOT/Scripts/build-runtime.sh"; fi
xcrun clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=15.0 \
    -I "$ROOT/Runtime/include" "$ROOT/Runtime/Tests/RuntimeSmoke.cpp" "$LIBRARY" \
    -framework Accelerate -o "$CACHE/runtime-smoke"
xcrun swiftc -swift-version 6 -O -target arm64-apple-macos15 \
    -I "$ROOT/Runtime/include" "$ROOT/Sources/Engine/LocalTranslationEngine.swift" \
    "$ROOT/Runtime/Tests/EngineSmoke.swift" "$LIBRARY" -Xlinker -lc++ \
    -framework Accelerate -o "$CACHE/engine-smoke"
for MODEL in "$@"; do
    echo "Testing $(basename "$MODEL")"
    /usr/bin/time -l "$CACHE/runtime-smoke" "$MODEL"
    /usr/bin/time -l "$CACHE/engine-smoke" "$MODEL"
done
