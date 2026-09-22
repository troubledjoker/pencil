#!/usr/bin/env bash
# One-time: creates a persistent self-signed code-signing identity "Pencil Local Signing"
# in the login keychain. Signing every build with the same identity keeps Pencil's
# code identity stable, so macOS privacy grants (Screen Recording) survive rebuilds.
set -euo pipefail

NAME="Pencil Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists in the login keychain."
    exit 0
fi

OPENSSL="$(command -v openssl)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

# macOS' importer wants the older PKCS#12 encryption; OpenSSL 3 needs -legacy for that.
PASS="pencil-$$-$RANDOM"
LEGACY=""
if "$OPENSSL" version | grep -q "^OpenSSL 3"; then LEGACY="-legacy"; fi
"$OPENSSL" pkcs12 -export $LEGACY -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS"

# -T lets codesign use the private key without a keychain prompt.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -f pkcs12 \
    -T /usr/bin/codesign -T /usr/bin/security

echo "Imported \"$NAME\" into the login keychain."
