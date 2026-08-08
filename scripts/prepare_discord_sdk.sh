#!/usr/bin/env bash
set -euo pipefail

ZIP="VendorUpload/discord_partner_sdk.zip"
HEADER="VendorUpload/discordpp.h"
C_HEADER="VendorUpload/cdiscord.h"

if [[ ! -f "$ZIP" ]]; then
  echo "::error::discord_partner_sdk.zip not found"
  exit 1
fi

if [[ ! -f "$HEADER" ]]; then
  echo "::error::discordpp.h not found"
  exit 1
fi

if [[ ! -f "$C_HEADER" ]]; then
  echo "::error::cdiscord.h not found"
  exit 1
fi

rm -rf Vendor

mkdir -p Vendor/include
mkdir -p Vendor/Frameworks

TMP="$(mktemp -d)"

unzip -q "$ZIP" -d "$TMP"

FRAMEWORK="$(find "$TMP" -type d -name 'discord_partner_sdk.framework' -print -quit)"

if [[ -z "$FRAMEWORK" ]]; then
  echo "::error::discord_partner_sdk.framework not found in ZIP"
  find "$TMP" -maxdepth 5 -print
  exit 1
fi

cp -R "$FRAMEWORK" Vendor/Frameworks/discord_partner_sdk.framework

cp "$HEADER" Vendor/include/discordpp.h
cp "$C_HEADER" Vendor/include/cdiscord.h

echo "=== Discord SDK prepared ==="
find Vendor -maxdepth 5 -print

echo "=== Framework contents ==="
find Vendor/Frameworks/discord_partner_sdk.framework -maxdepth 3 -print
