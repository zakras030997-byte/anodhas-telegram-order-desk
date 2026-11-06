#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
RELEASE_DIR="$PROJECT_ROOT/releases/1.0.0"
STAGING="$PROJECT_ROOT/.build/installer-image"
APP_NAME="Заказы из Telegram.app"
APP="$RELEASE_DIR/$APP_NAME"
DMG="$RELEASE_DIR/Telegram-Order-Desk-1.0.0-universal.dmg"
test -f "$APP/Contents/MacOS/TelegramOrderDesk"
codesign --verify --deep --strict "$APP"
mkdir -p "$STAGING" "$PROJECT_ROOT/Verification"
ditto "$APP" "$STAGING/$APP_NAME"
if [ ! -L "$STAGING/Программы" ]; then ln -s /Applications "$STAGING/Программы"; fi
cp Resources/Установка.txt "$STAGING/Установка.txt"
hdiutil create -volname "Заказы из Telegram" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
hdiutil verify "$DMG" > Verification/dmg-verification.txt
shasum -a 256 "$DMG" "$APP/Contents/MacOS/TelegramOrderDesk" > Verification/SHA256.txt
echo "$DMG"
