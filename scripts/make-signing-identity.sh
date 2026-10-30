#!/usr/bin/env bash
#
# Create a self-signed code-signing identity for local builds, once per Mac.
# macOS ties the Microphone permission to the code signature; with this
# identity the signature stays the same across rebuilds, so macOS asks once.
# It lives in its own keychain with a fixed password, so builds over SSH can
# use it unattended. scripts/build-run.sh signs with it.
#
#   scripts/make-signing-identity.sh
#
# Never re-create it once apps are signed with it: a new certificate is a new
# identity, and macOS asks for every permission again.
set -euo pipefail

NAME="MPX Prime Development"
KEYCHAIN="$HOME/Library/Keychains/mpx-prime-dev.keychain-db"
KEYCHAIN_PASSWORD="mpx-prime-dev"

if [ -f "$KEYCHAIN" ]; then
    echo "Signing keychain already exists: $KEYCHAIN"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/cert.cnf" <<EOF
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
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -passout pass:transfer -out "$WORK/identity.p12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P transfer -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# Add it to the user's search list so codesign finds the identity.
SEARCH=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    SEARCH+=("${line//\"/}")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN" "${SEARCH[@]}"
echo "Created $NAME in $KEYCHAIN"
