#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
mkdir -p "$PROJECT_ROOT/.build/share-images" "$PROJECT_ROOT/docs/images"
/usr/bin/xcrun swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
    "$PROJECT_ROOT/Scripts/ShareImage.swift" -o "$PROJECT_ROOT/.build/share-images/render"
"$PROJECT_ROOT/.build/share-images/render" "$PROJECT_ROOT"
