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
mkdir -p Vendor/discord_partner_sdk.xcframework/ios-arm64

TMP="$(mktemp -d)"

unzip -q "$ZIP" -d "$TMP"

FRAMEWORK="$(find "$TMP" -type d -name 'discord_partner_sdk.framework' -print -quit)"

if [[ -z "$FRAMEWORK" ]]; then
  echo "::error::discord_partner_sdk.framework not found in ZIP"
  find "$TMP" -maxdepth 4 -print
  exit 1
fi

cp -R "$FRAMEWORK" \
  Vendor/discord_partner_sdk.xcframework/ios-arm64/

cp "$HEADER" Vendor/include/discordpp.h
cp "$C_HEADER" Vendor/include/cdiscord.h

cat > Vendor/discord_partner_sdk.xcframework/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>LibraryIdentifier</key>
            <string>ios-arm64</string>

            <key>LibraryPath</key>
            <string>discord_partner_sdk.framework</string>

            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
            </array>

            <key>SupportedPlatform</key>
            <string>ios</string>
        </dict>
    </array>

    <key>CFBundlePackageType</key>
    <string>XFWK</string>

    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
PLIST

echo "Discord SDK prepared:"
find Vendor -maxdepth 4 -print
