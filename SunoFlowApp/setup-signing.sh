#!/bin/bash
# Creates a stable self-signed code-signing identity ("SunoFlow Self-Signed")
# in your login keychain, so macOS keeps the app's Microphone and Accessibility
# permissions across rebuilds instead of resetting them every time.
#
# Safe to run more than once; it skips creation if the identity already exists.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY_NAME="SunoFlow Self-Signed"
SIGN_DIR="signing"
P12_PASSWORD="sunoflow"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "$IDENTITY_NAME"; then
    echo "Identity '$IDENTITY_NAME' already present in the keychain. Nothing to do."
    exit 0
fi

mkdir -p "$SIGN_DIR"

if [ ! -f "$SIGN_DIR/sunoflow.p12" ]; then
    echo "Generating self-signed code-signing certificate..."
    cat > "$SIGN_DIR/sunoflow-cert.conf" <<'EOF'
[ req ]
distinguished_name = req_dn
x509_extensions = v3_ext
prompt = no
[ req_dn ]
CN = SunoFlow Self-Signed
[ v3_ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
    openssl req -x509 -newkey rsa:2048 \
        -keyout "$SIGN_DIR/sunoflow-key.pem" \
        -out "$SIGN_DIR/sunoflow-cert.pem" \
        -days 3650 -nodes -config "$SIGN_DIR/sunoflow-cert.conf"
    # -legacy: Apple's security tool can't import OpenSSL 3's default PKCS#12 MAC.
    openssl pkcs12 -export \
        -inkey "$SIGN_DIR/sunoflow-key.pem" \
        -in "$SIGN_DIR/sunoflow-cert.pem" \
        -out "$SIGN_DIR/sunoflow.p12" \
        -name "$IDENTITY_NAME" -legacy -passout "pass:$P12_PASSWORD"
fi

echo "Importing certificate into login keychain..."
security import "$SIGN_DIR/sunoflow.p12" -k "$LOGIN_KC" -P "$P12_PASSWORD" -T /usr/bin/codesign -A

echo ""
echo "Done. Verify with:  security find-identity -p codesigning"
echo "Now run ./build.sh — it will sign with '$IDENTITY_NAME'."
