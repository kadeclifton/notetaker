#!/usr/bin/env bash
# One-time setup: creates a self-signed "Murmur Dev" code-signing certificate in your login
# keychain. scripts/build-app.sh then signs with it automatically.
#
# Why: macOS ties Accessibility, Input Monitoring and Screen Recording grants to the app's
# signature. Without a certificate every build gets a new ad-hoc signature and the grants stop
# applying, even though System Settings still shows them switched on. With this certificate the
# signature stays the same from build to build, so you grant the permissions once.
#
# macOS asks for your password once, to trust the certificate for code signing. The certificate
# only exists on this Mac and can only sign code; delete it any time in Keychain Access.
#
#   scripts/setup-signing.sh
#
# Environment (mostly for CI):
#   CODESIGN_IDENTITY   certificate name (default "Murmur Dev")
#   MURMUR_KEYCHAIN     keychain to use (default: your login keychain)
#   MURMUR_TRUST        "user" (default, asks for your password), "admin" (via sudo), or "none"
set -euo pipefail

NAME="${CODESIGN_IDENTITY:-Murmur Dev}"
KEYCHAIN="${MURMUR_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
TRUST="${MURMUR_TRUST:-user}"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "This script sets up code signing on macOS." >&2
    exit 1
fi

if security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "\"$NAME\" is already set up. scripts/build-app.sh will use it."
    exit 0
fi

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "A certificate named \"$NAME\" exists but is not usable for code signing." >&2
    echo "Delete it in Keychain Access (login keychain, My Certificates) and run this again." >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# Apple's /usr/bin/openssl (LibreSSL) writes a .p12 that `security import` always accepts;
# a Homebrew OpenSSL 3 earlier in PATH may not.
OPENSSL=/usr/bin/openssl
PASSWORD="$("$OPENSSL" rand -hex 16)"

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout "pass:$PASSWORD"

# -T lets codesign use the key without asking each time.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign
echo "Added \"$NAME\" to $KEYCHAIN."

case "$TRUST" in
    user)
        echo "macOS will now ask for your password to trust \"$NAME\" for code signing."
        security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
        ;;
    admin)
        sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$TMP/cert.pem"
        ;;
    none)
        ;;
    *)
        echo "MURMUR_TRUST must be user, admin or none." >&2
        exit 1
        ;;
esac

if security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo
    echo "Done. Next:"
    echo "  1. scripts/build-app.sh --install"
    echo "  2. Grant Accessibility, Input Monitoring (and Screen Recording for meetings) one last time."
    echo "     From now on rebuilds keep them."
else
    echo "The certificate was added but macOS does not list it as usable for code signing yet." >&2
    echo "Open Keychain Access, find \"$NAME\", and under Trust set Code Signing to Always Trust." >&2
    exit 1
fi
