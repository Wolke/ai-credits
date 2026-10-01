#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
SIGNING_DIR="$HOME/Library/Application Support/AICredits/Signing"
identity=$(<"$SIGNING_DIR/identity.sha1")
[[ "$identity" =~ '^[A-F0-9]{40}$' ]] || exit 1
HELPER="$PROJECT_ROOT/dist/AI Credits.app/Contents/Helpers/AICreditsKeychain"
probe_tmp=$(mktemp -d "$PROJECT_ROOT/.build/signing-probe.XXXXXX")
trap 'rm -rf "$probe_tmp"' EXIT
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"

# Simulate two updated app binaries sharing the same signing identity.
cp "$PROJECT_ROOT/Scripts/SigningProbe.swift" "$probe_tmp/main.swift"
for version in version-one version-two; do
    probe_app="$probe_tmp/$version.app"
    mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/Helpers"
    cp "$PROJECT_ROOT/Resources/Info.plist" "$probe_app/Contents/Info.plist"
    cp "$HELPER" "$probe_app/Contents/Helpers/AICreditsKeychain"
    print "print(\"$version\")" >> "$probe_tmp/main.swift"
    /usr/bin/xcrun swiftc -D REAL_CLIENT "$probe_tmp/main.swift" \
        "$PROJECT_ROOT/Sources/AICreditsApp/Services/KeychainService.swift" -o "$probe_app/Contents/MacOS/AICredits"
    /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp=none \
        --identifier com.local.AICredits \
        --requirements "=designated => identifier \"com.local.AICredits\" and certificate leaf = H\"$identity\"" \
        "$probe_app"
done
first="$probe_tmp/version-one.app/Contents/MacOS/AICredits"
second="$probe_tmp/version-two.app/Contents/MacOS/AICredits"

# An arbitrary caller must be rejected before the helper touches Keychain.
/usr/bin/xcrun swiftc "$PROJECT_ROOT/Scripts/SigningProbe.swift" -o "$probe_tmp/untrusted"
"$probe_tmp/untrusted" "$HELPER" rejected
"$probe_tmp/untrusted" "$HELPER" seed-legacy
trap '"$probe_tmp/untrusted" "$HELPER" cleanup-legacy >/dev/null 2>&1; rm -rf "$probe_tmp"' EXIT
"$first" "$HELPER" blocked
"$probe_tmp/untrusted" "$HELPER" cleanup-legacy
"$first" "$HELPER" set
trap '"$first" "$HELPER" delete >/dev/null 2>&1; rm -rf "$probe_tmp"' EXIT
"$second" "$HELPER" get
"$second" "$HELPER" delete
print "Updated signed application reused the same Keychain helper without a password prompt."
