#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="$ROOT_DIR/macos"
DIST_DIR="$MACOS_DIR/dist"
APP_BUNDLE="$DIST_DIR/BrokBot.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_BIN_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "[BrokBot] Building release binary via SwiftPM..."
cd "$MACOS_DIR"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR/BrokBotApp"
if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "Error: Built executable not found at $EXECUTABLE_PATH" >&2
    exit 1
fi

echo "[BrokBot] Assembling app bundle at $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_BIN_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_BIN_DIR/BrokBotApp"
chmod +x "$MACOS_BIN_DIR/BrokBotApp"

ICON_SRC="$MACOS_DIR/Sources/BrokBotApp/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"
fi

for BUNDLE_SRC in "$BIN_DIR"/*.bundle; do
    if [[ -d "$BUNDLE_SRC" ]]; then
        cp -R "$BUNDLE_SRC" "$RESOURCES_DIR/"
    fi
done

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>BrokBotApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>org.brokbot.mac</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>BrokBot</string>
    <key>CFBundleDisplayName</key>
    <string>Brok Bot</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "[BrokBot] Ad-hoc signing BrokBot.app..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "[BrokBot] Verifying signature..."
codesign --verify --deep --strict "$APP_BUNDLE"

echo "[BrokBot] Build & ad-hoc sign succeeded: $APP_BUNDLE"
