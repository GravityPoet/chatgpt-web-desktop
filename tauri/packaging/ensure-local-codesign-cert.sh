#!/bin/bash
set -euo pipefail

IDENTITY="${CHATGPT_RUST_CODESIGN_IDENTITY:-ChatGPT Rust Local Code Signing}"
KEYCHAIN="${CHATGPT_RUST_CODESIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
P12_PASSWORD="${CHATGPT_RUST_CODESIGN_P12_PASSWORD:-chatgpt-rust-local}"

if /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | /usr/bin/grep -Fq "\"$IDENTITY\""; then
  printf '%s\n' "$IDENTITY"
  exit 0
fi

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/chatgpt-rust-codesign.XXXXXX")"
cleanup() {
  /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

OPENSSL_CONF="$WORK_DIR/openssl.cnf"
KEY_PATH="$WORK_DIR/codesign.key"
CERT_PATH="$WORK_DIR/codesign.crt"
P12_PATH="$WORK_DIR/codesign.p12"

/bin/cat >"$OPENSSL_CONF" <<EOF
[req]
distinguished_name = dn
x509_extensions = codesign_ext
prompt = no

[dn]
CN = $IDENTITY

[codesign_ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical, CA:true
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req \
  -x509 \
  -newkey rsa:2048 \
  -nodes \
  -days 3650 \
  -keyout "$KEY_PATH" \
  -out "$CERT_PATH" \
  -config "$OPENSSL_CONF" \
  >/dev/null 2>&1

/usr/bin/openssl pkcs12 \
  -export \
  -inkey "$KEY_PATH" \
  -in "$CERT_PATH" \
  -out "$P12_PATH" \
  -passout "pass:$P12_PASSWORD" \
  >/dev/null 2>&1

/usr/bin/security import "$P12_PATH" \
  -k "$KEYCHAIN" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  >/dev/null

/usr/bin/security add-trusted-cert \
  -d \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN" \
  "$CERT_PATH" \
  >/dev/null 2>&1 || true

/usr/bin/security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "" \
  "$KEYCHAIN" \
  >/dev/null 2>&1 || true

if ! /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | /usr/bin/grep -Fq "\"$IDENTITY\""; then
  echo "failed to create local code signing identity: $IDENTITY" >&2
  exit 1
fi

printf '%s\n' "$IDENTITY"
