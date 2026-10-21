#!/usr/bin/env bash
# Creates a private code-signing certificate on this Mac (once), named
# "Driftdock Local Signing". Signing every build with the same certificate means
# macOS remembers Accessibility, Automation and other permissions across rebuilds.
# The certificate never leaves your Mac and is only trusted for signing Driftdock here.
set -euo pipefail
NAME="Driftdock Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "✓ \"$NAME\" already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Creating \"$NAME\" certificate…"
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout pass:driftdock >/dev/null 2>&1

# -T lets codesign use the key (macOS may still ask once: click "Always Allow").
security import "$TMP/id.p12" -k "$KEYCHAIN" -P driftdock -T /usr/bin/codesign >/dev/null

echo "✓ Created. Future builds are signed with it, so permissions stick."
