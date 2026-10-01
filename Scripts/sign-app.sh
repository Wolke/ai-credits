#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
APP_ROOT="${1:-$PROJECT_ROOT/dist/AI Credits.app}"
SIGNING_DIR="$HOME/Library/Application Support/AICredits/Signing"
[[ -s "$SIGNING_DIR/identity.sha1" ]] || {
    print -u2 "Run Scripts/setup-signing.sh once before building."
    exit 1
}
identity=$(<"$SIGNING_DIR/identity.sha1")
[[ "$identity" =~ '^[A-F0-9]{40}$' ]] || { print -u2 "Invalid signing identity fingerprint."; exit 1; }
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"

# Keep this signed binary byte-for-byte across app upgrades: self-signed code also has
# a per-binary Keychain partition. Re-signing the main app alone is insufficient.
helper_hash=$( { cat "$PROJECT_ROOT/Scripts/KeychainHelper.swift"; print -r -- "$identity"; } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
HELPER_DIR="$SIGNING_DIR/helpers/$helper_hash"
HELPER="$HELPER_DIR/AICreditsKeychain"
helper_requirement="identifier \"com.local.AICredits.keychain\" and certificate leaf = H\"$identity\""
app_requirement="identifier \"com.local.AICredits\" and certificate leaf = H\"$identity\""

if [[ ! -f "$HELPER" ]]; then
    mkdir -p "$HELPER_DIR"
    signing_build=$(mktemp -d "$PROJECT_ROOT/.build/signing.XXXXXX")
    trap 'rm -rf "$signing_build"' EXIT
    cp "$PROJECT_ROOT/Scripts/KeychainHelper.swift" "$signing_build/main.swift"
    print -r -- "enum SigningIdentity { static let fingerprint = \"$identity\" }" > "$signing_build/SigningIdentity.swift"
    /usr/bin/xcrun swiftc -O "$signing_build/main.swift" "$signing_build/SigningIdentity.swift" -o "$signing_build/AICreditsKeychain"
    /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp=none --identifier com.local.AICredits.keychain \
        --requirements "=designated => $helper_requirement" "$signing_build/AICreditsKeychain"
    /usr/bin/codesign --verify --strict -R "=$helper_requirement" "$signing_build/AICreditsKeychain"
    mv "$signing_build/AICreditsKeychain" "$HELPER"
fi
/usr/bin/codesign --verify --strict -R "=$helper_requirement" "$HELPER"
mkdir -p "$APP_ROOT/Contents/Helpers"
cp "$HELPER" "$APP_ROOT/Contents/Helpers/AICreditsKeychain"
/usr/bin/codesign --force --sign "$identity" --options runtime --timestamp=none \
    --requirements "=designated => $app_requirement" "$APP_ROOT"
/usr/bin/codesign --verify --deep --strict "$APP_ROOT"
print "Signed with persistent local identity: $identity"
