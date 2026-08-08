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

# __MACOSX を除外して、本物の framework だけ探す
FRAMEWORK="$(find "$TMP" \
  -type d \
  -name 'discord_partner_sdk.framework' \
  ! -path '*/__MACOSX/*' \
  -print -quit)"

if [[ -z "$FRAMEWORK" ]]; then
  echo "::error::Real discord_partner_sdk.framework not found"
  exit 1
fi

echo "=== Real framework found ==="
echo "$FRAMEWORK"

DEST="Vendor/Frameworks/discord_partner_sdk.framework"

cp -R "$FRAMEWORK" "$DEST"

cp "$HEADER" Vendor/include/discordpp.h
cp "$C_HEADER" Vendor/include/cdiscord.h

echo "=== Framework contents ==="
find "$DEST" -maxdepth 4 -print

if [[ ! -f "$DEST/discord_partner_sdk" ]]; then
  echo "::error::discord_partner_sdk binary not found"
  exit 1
fi

if [[ ! -f "$DEST/Info.plist" ]]; then
  echo "::error::Info.plist not found"
  exit 1
fi

echo "=== Framework binary ==="
file "$DEST/discord_partner_sdk"

echo "=== Info.plist ==="
plutil -p "$DEST/Info.plist"

echo "=== Final Vendor structure ==="
find Vendor -maxdepth 5 -print

echo "Discord SDK prepared successfully."
