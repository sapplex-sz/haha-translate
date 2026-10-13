#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${HAHA_BUILD_CACHE:-$HOME/Library/Caches/HaHaTranslateDevelopment/runtime}"
if [[ $# -ne 3 ]]; then
    echo 'Usage: run-evaluation.sh LIGHT_GGUF STANDARD_GGUF NEW_OUTPUT_JSONL' >&2
    exit 64
fi
LIGHT="$1"
STANDARD="$2"
OUTPUT="$3"
if [[ -e "$OUTPUT" ]]; then
    echo "Refusing to overwrite raw evidence: $OUTPUT" >&2
    exit 73
fi
LIBRARY="$ROOT/Runtime/CHaHaRuntime.xcframework/macos-arm64/libCHaHaRuntime.a"
mkdir -p "$CACHE" "$(dirname "$OUTPUT")"
xcrun clang -O2 -arch arm64 -mmacosx-version-min=15.0 \
    -c "$ROOT/Runtime/Tests/MemoryProbe.c" -o "$CACHE/MemoryProbe.o"
xcrun swiftc -swift-version 6 -O -target arm64-apple-macos15 \
    -I "$ROOT/Runtime/include" "$ROOT/Sources/Engine/LocalTranslationEngine.swift" \
    "$ROOT/Sources/Core/TextProcessing.swift" "$ROOT/Runtime/Tests/ModelEvaluation.swift" \
    "$CACHE/MemoryProbe.o" "$LIBRARY" -Xlinker -lc++ -framework Accelerate \
    -framework NaturalLanguage -o "$CACHE/model-evaluation"
"$CACHE/model-evaluation" "$ROOT/docs/Validation/model-evaluation-inputs.json" \
    "$OUTPUT" "$LIGHT" "$STANDARD"
