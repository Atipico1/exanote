#!/bin/bash
# Executed only inside the reviewer-gated release job. Never echo secret values.
set -euo pipefail
umask 077
for name in CERTIFICATE_P12_BASE64 CERTIFICATE_PASSWORD NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID SPARKLE_PRIVATE_KEY; do
  [ -n "${!name:-}" ] || { echo "Missing release environment secret: $name" >&2; exit 1; }
done
KEYCHAIN="$RUNNER_TEMP/exanote-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
echo "::add-mask::$KEYCHAIN_PASSWORD"
printf '%s' "$CERTIFICATE_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/certificate.p12"
printf '%s' "$NOTARY_KEY_P8" > "$RUNNER_TEMP/notary.p8"
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$RUNNER_TEMP/sparkle.key"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$RUNNER_TEMP/certificate.p12" -P "$CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" login.keychain-db
xcrun notarytool store-credentials "$NOTARY_PROFILE" --key "$RUNNER_TEMP/notary.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --keychain "$KEYCHAIN"
