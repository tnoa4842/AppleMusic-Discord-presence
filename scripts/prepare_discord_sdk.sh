#!/usr/bin/env bash
set -euo pipefail

ZIP="${1:-VendorUpload/discord-social-sdk.zip}"

if [[ ! -f "$ZIP" ]]; then
  echo "::error::Discord SDK ZIP not found at $ZIP"
  exit 1
fi

rm -rf /tmp/discord-sdk Vendor
mkdir -p /tmp/discord-sdk Vendor/include

unzip -q "$ZIP" -d /tmp/discord-sdk

FRAMEWORK="$(find /tmp/discord-sdk -type d -name 'discord_partner_sdk.xcframework' | head -n 1 || true)"
HEADER="$(find /tmp/discord-sdk -type f -name 'discordpp.h' | head -n 1 || true)"

if [[ -z "$FRAMEWORK" || -z "$HEADER" ]]; then
  echo "::error::Could not find discord_partner_sdk.xcframework and/or discordpp.h in SDK ZIP"
  find /tmp/discord-sdk -maxdepth 4 -print | head -n 200
  exit 1
fi

cp -R "$FRAMEWORK" Vendor/discord_partner_sdk.xcframework
cp "$HEADER" Vendor/include/discordpp.h

echo "Discord SDK prepared."
