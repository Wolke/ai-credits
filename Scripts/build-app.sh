#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
BUILD_ROOT="$PROJECT_ROOT/.build"
APP_ROOT="$PROJECT_ROOT/dist/AI Credits.app"
CONTENTS="$APP_ROOT/Contents"

export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/ModuleCache"

cd "$PROJECT_ROOT"
swift "$PROJECT_ROOT/Scripts/make-icon.swift" "$PROJECT_ROOT/Resources/AppIcon.svg" "$BUILD_ROOT/AppIcon.iconset" "$PROJECT_ROOT/Resources/AppIcon.icns"
swift build -c release --disable-sandbox --scratch-path "$BUILD_ROOT"

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BUILD_ROOT/release/AICredits" "$CONTENTS/MacOS/AICredits"
cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
"$PROJECT_ROOT/Scripts/sign-app.sh" "$APP_ROOT"

echo "$APP_ROOT"
