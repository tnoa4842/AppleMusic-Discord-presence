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

echo "=== ZIP contents ==="
find "$TMP" -maxdepth 6 -print

FRAMEWORK="$(find "$TMP" -type d -name '*.framework' -print -quit)"

if [[ -z "$FRAMEWORK" ]]; then
  echo "::error::No .framework found in ZIP"
  exit 1
fi

echo "=== Found framework ==="
echo "$FRAMEWORK"

echo "=== Framework contents ==="
find "$FRAMEWORK" -maxdepth 4 -print

cp -R "$FRAMEWORK" Vendor/Frameworks/

cp "$HEADER" Vendor/include/discordpp.h
cp "$C_HEADER" Vendor/include/cdiscord.h

echo "=== Copied Vendor structure ==="
find Vendor -maxdepth 6 -print

echo "=== Framework Info.plist ==="
if [[ -f "Vendor/Frameworks/$(basename "$FRAMEWORK")/Info.plist" ]]; then
  plutil -p "Vendor/Frameworks/$(basename "$FRAMEWORK")/Info.plist"
fi

echo "=== Framework binary candidates ==="
find "Vendor/Frameworks/$(basename "$FRAMEWORK")" -maxdepth 1 -type f -print

echo "Discord SDK prepared."
