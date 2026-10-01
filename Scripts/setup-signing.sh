#!/bin/zsh
set -euo pipefail
umask 077

SIGNING_DIR="$HOME/Library/Application Support/AICredits/Signing"
IDENTITY_NAME="AI Credits Local Signing"
mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

# This fingerprint is public metadata. The private key lives only in the login keychain.
if [[ -s "$SIGNING_DIR/identity.sha1" ]]; then
    identity=$(<"$SIGNING_DIR/identity.sha1")
    /usr/bin/security find-identity -p codesigning | /usr/bin/grep -F "$identity" >/dev/null || {
        print -u2 "The saved signing identity is unavailable. Restore it instead of generating a new identity."
        exit 1
    }
    print "Reusing AI Credits signing identity: $identity"
    exit 0
fi

if /usr/bin/security find-certificate -c "$IDENTITY_NAME" -p > "$SIGNING_DIR/certificate.pem" 2>/dev/null; then
    print "Reusing the existing local certificate."
else
    signing_tmp=$(mktemp -d "${TMPDIR:-/tmp/}aicredits-signing.XXXXXX")
    trap 'rm -rf "$signing_tmp"' EXIT
    cat > "$signing_tmp/openssl.cnf" <<'EOF'
[req]
distinguished_name = name
x509_extensions = signing
prompt = no
[name]
CN = AI Credits Local Signing
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
    /usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
        -config "$signing_tmp/openssl.cnf" -keyout "$signing_tmp/private.key" \
        -out "$signing_tmp/certificate.pem" 2> "$signing_tmp/openssl.log"
    cat "$signing_tmp/private.key" "$signing_tmp/certificate.pem" > "$signing_tmp/identity.pem"
    login_keychain=$(/usr/bin/security default-keychain -d user | /usr/bin/xargs)
    # Authorize only codesign to use this non-exportable signing key.
    /usr/bin/security import "$signing_tmp/identity.pem" -k "$login_keychain" -f pemseq -t agg -x -T /usr/bin/codesign
    cp "$signing_tmp/certificate.pem" "$SIGNING_DIR/certificate.pem"
fi

identity=$(/usr/bin/openssl x509 -in "$SIGNING_DIR/certificate.pem" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//;s/://g')
[[ "$identity" =~ '^[A-F0-9]{40}$' ]] || exit 1
/usr/bin/security find-identity -p codesigning | /usr/bin/grep -F "$identity" >/dev/null || {
    print -u2 "Certificate found without its private key. Restore the signing identity before continuing."
    exit 1
}
print -r -- "$identity" > "$SIGNING_DIR/identity.sha1"
print "Local signing identity ready: $identity"
