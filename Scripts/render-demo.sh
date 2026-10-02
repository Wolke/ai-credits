#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
DEMO_ROOT="$PROJECT_ROOT/.build/demo"
DEMO_APP="$DEMO_ROOT/Preview.app"
mkdir -p "$DEMO_APP/Contents/MacOS" "$PROJECT_ROOT/docs/images"
cp "$PROJECT_ROOT/Resources/Info.plist" "$DEMO_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable MenuPreview' "$DEMO_APP/Contents/Info.plist"

sources=("$PROJECT_ROOT"/Sources/AICreditsApp/**/*.swift)
sources=("${(@)sources:#*/AICreditsApp.swift}")
/usr/bin/xcrun swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
    "${sources[@]}" "$PROJECT_ROOT/Scripts/DemoPreview.swift" \
    -o "$DEMO_APP/Contents/MacOS/MenuPreview"
"$DEMO_APP/Contents/MacOS/MenuPreview" "$PROJECT_ROOT/docs/images/menu-preview.png"
