#!/usr/bin/env bash
set -euo pipefail

APP_PATH="$(find build -path '*Release-iphoneos/AppleMusicDiscordPresence.app' -type d | head -n 1)"
if [[ -z "$APP_PATH" ]]; then
  echo "::error::Built .app not found"
  exit 1
fi

rm -rf Payload
mkdir Payload
cp -R "$APP_PATH" Payload/
zip -qry AppleMusicDiscordPresence-unsigned.ipa Payload
