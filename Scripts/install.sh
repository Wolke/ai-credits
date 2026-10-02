#!/bin/zsh
# Build and install from this checkout. Does not download or run remote scripts.
set -euo pipefail
umask 077

PROJECT_ROOT="${0:A:h:h}"
INSTALL_DIR="$HOME/Applications"
[[ ! -e "/Applications/AI Credits.app" ]] || INSTALL_DIR="/Applications"
OPEN_AFTER_INSTALL=true

usage() {
    cat <<'EOF'
Usage: ./Scripts/install.sh [--destination DIRECTORY] [--no-open]

Build, locally sign, and install AI Credits. Requires macOS 14+ and Swift 6+.
Defaults to ~/Applications, or /Applications when AI Credits is already there.
Quit the installed app before updating. Do not run this script with sudo.
EOF
}

fail() { print -u2 -- "$1"; exit 1; }

while (( $# )); do
    case "$1" in
        --destination)
            (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || fail "--destination requires a directory."
            INSTALL_DIR="${2:A}"
            shift 2
            ;;
        --no-open) OPEN_AFTER_INSTALL=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; fail "Unknown option: $1" ;;
    esac
done

[[ "$(uname -s)" == Darwin ]] || fail "AI Credits requires macOS."
(( EUID != 0 )) || fail "Run as your normal macOS user, without sudo."
os_version=$(/usr/bin/sw_vers -productVersion)
(( ${os_version%%.*} >= 14 )) || fail "macOS 14 or newer is required."
/usr/bin/xcode-select -p >/dev/null 2>&1 || fail "Install Xcode Command Line Tools: xcode-select --install"
swift_version=$(/usr/bin/xcrun swift --version) || fail "Swift is unavailable. Install a compatible Xcode / Command Line Tools."
swift_major=$(print -r -- "$swift_version" | /usr/bin/sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | /usr/bin/head -n 1)
[[ -n "$swift_major" ]] && (( swift_major >= 6 )) || fail "Swift 6+ is required. Update Xcode / Command Line Tools."

INSTALL_APP="$INSTALL_DIR/AI Credits.app"
[[ "$INSTALL_APP" != "$PROJECT_ROOT/dist/AI Credits.app" ]] || fail "Choose an install directory outside dist."
[[ ! -L "$INSTALL_APP" ]] || fail "The destination app is a symbolic link; choose a different destination."
if [[ -e "$INSTALL_APP" ]]; then
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_APP/Contents/Info.plist" 2>/dev/null) || fail "Destination is not an AI Credits app."
    [[ "$bundle_id" == com.local.AICredits ]] || fail "Refusing to replace an unrelated app."
fi

ensure_app_is_closed() {
    local running_processes
    running_processes=$(/bin/ps -axww -o uid=,comm=) || fail "Cannot inspect running apps. Run this installer from Terminal."
    if print -r -- "$running_processes" | /usr/bin/awk -v uid="$EUID" -v executable="$INSTALL_APP/Contents/MacOS/AICredits" '
        $1 == uid { sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == executable) found = 1 }
        END { exit !found }
    '; then
        fail "Quit AI Credits from its menu bar menu, then run this installer again."
    fi
}

ensure_app_is_closed
mkdir -p "$INSTALL_DIR"
[[ -w "$INSTALL_DIR" ]] || fail "Destination is not writable. Use --destination \"\$HOME/Applications\" (without sudo)."

"$PROJECT_ROOT/Scripts/setup-signing.sh"
"$PROJECT_ROOT/Scripts/build-app.sh"
ensure_app_is_closed

# Stage on the destination volume so renames remain local; keep a rollback copy.
install_stage=$(mktemp -d "$INSTALL_DIR/.ai-credits-install.XXXXXX")
cleanup() {
    # Restore on failure or interruption between the two destination renames.
    if [[ -d "$install_stage/previous.app" && ! -e "$INSTALL_APP" ]]; then
        mv "$install_stage/previous.app" "$INSTALL_APP" || return
    fi
    rm -rf "$install_stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/ditto "$PROJECT_ROOT/dist/AI Credits.app" "$install_stage/AI Credits.app"
/usr/bin/codesign --verify --deep --strict "$install_stage/AI Credits.app"

if [[ -e "$INSTALL_APP" ]]; then
    backup_root="$HOME/Library/Application Support/AICredits/Backups"
    mkdir -p "$backup_root"
    backup_dir=$(mktemp -d "$backup_root/install-$(date +%Y%m%d-%H%M%S).XXXXXX")
    /usr/bin/ditto "$INSTALL_APP" "$backup_dir/AI Credits.app"
    data_file="$HOME/Library/Application Support/AICredits/credits.json"
    [[ ! -f "$data_file" ]] || cp "$data_file" "$backup_dir/credits.json"
    print -r -- "Backup: $backup_dir"
    mv "$INSTALL_APP" "$install_stage/previous.app"
fi

if ! mv "$install_stage/AI Credits.app" "$INSTALL_APP"; then
    [[ ! -d "$install_stage/previous.app" ]] || mv "$install_stage/previous.app" "$INSTALL_APP"
    fail "Installation failed; the previous app was restored when available."
fi

print -r -- "Installed: $INSTALL_APP"
print -- "API keys and existing balances are preserved."
if $OPEN_AFTER_INSTALL; then
    /usr/bin/open "$INSTALL_APP"
fi
