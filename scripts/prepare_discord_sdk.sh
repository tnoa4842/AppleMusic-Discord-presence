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
  echo "::error::No .framework found inside ZIP"
  exit 1
fi

echo "=== Original framework ==="
echo "$FRAMEWORK"

# 名前を必ず discord_partner_sdk.framework に統一
DEST="Vendor/Frameworks/discord_partner_sdk.framework"

cp -R "$FRAMEWORK" "$DEST"

cp "$HEADER" Vendor/include/discordpp.h
cp "$C_HEADER" Vendor/include/cdiscord.h

echo "=== Framework before normalization ==="
find "$DEST" -maxdepth 3 -print

# Info.plistから本来の実行バイナリ名を取得
EXECUTABLE=""

if [[ -f "$DEST/Info.plist" ]]; then
  EXECUTABLE="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleExecutable' \
    "$DEST/Info.plist" 2>/dev/null || true)"
fi

echo "CFBundleExecutable: $EXECUTABLE"

# framework内部の実体バイナリを探す
if [[ -n "$EXECUTABLE" && -f "$DEST/$EXECUTABLE" ]]; then
  echo "Found framework executable: $DEST/$EXECUTABLE"

  # -framework discord_partner_sdk が探す名前へ統一
  if [[ "$EXECUTABLE" != "discord_partner_sdk" ]]; then
    mv "$DEST/$EXECUTABLE" "$DEST/discord_partner_sdk"

    /usr/libexec/PlistBuddy \
      -c 'Set :CFBundleExecutable discord_partner_sdk' \
      "$DEST/Info.plist"
  fi
fi

# 上で見つからなかった場合、framework直下のMach-Oを探す
if [[ ! -f "$DEST/discord_partner_sdk" ]]; then
  echo "Searching for Mach-O binary..."

  while IFS= read -r FILE; do
    if file "$FILE" | grep -q "Mach-O"; then
      echo "Found Mach-O: $FILE"
      cp "$FILE" "$DEST/discord_partner_sdk"

      if [[ -f "$DEST/Info.plist" ]]; then
        /usr/libexec/PlistBuddy \
          -c 'Set :CFBundleExecutable discord_partner_sdk' \
          "$DEST/Info.plist" || true
      fi

      break
    fi
  done < <(find "$DEST" -maxdepth 1 -type f)
fi

if [[ ! -f "$DEST/discord_partner_sdk" ]]; then
  echo "::error::Framework binary could not be found"
  find "$DEST" -maxdepth 4 -print
  exit 1
fi

chmod +x "$DEST/discord_partner_sdk" || true

echo "=== FINAL Vendor structure ==="
find Vendor -maxdepth 5 -print

echo "=== Final framework binary ==="
file "$DEST/discord_partner_sdk"

echo "Discord SDK prepared successfully."
