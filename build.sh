#!/bin/bash
# MixRec をビルドして ~/Applications に入れ、起動するスクリプト
set -euo pipefail
cd "$(dirname "$0")"

# macOS 14.2 以上が必要（内部音声の取得に使う Core Audio Tap がそれ以降の機能のため）
OS_VERSION=$(sw_vers -productVersion)
if [ "$(printf '%s\n' "14.2" "$OS_VERSION" | sort -V | head -n1)" != "14.2" ]; then
  echo "このアプリは macOS 14.2 以上が必要です（今は $OS_VERSION）"
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc がありません。次を実行してから、もう一度このスクリプトを実行してください："
  echo "  xcode-select --install"
  exit 1
fi

ARCH=$(uname -m)
APP="build/MixRec.app"

echo "ビルド中…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -parse-as-library -swift-version 5 -O \
  -target "${ARCH}-apple-macos14.2" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/MixRec"

codesign --force --sign - "$APP"

mkdir -p "$HOME/Applications"
pkill -x MixRec 2>/dev/null || true
rm -rf "$HOME/Applications/MixRec.app"
cp -R "$APP" "$HOME/Applications/MixRec.app"

echo "できました。メニューバーに波形のアイコンが出ます。"
open "$HOME/Applications/MixRec.app"
