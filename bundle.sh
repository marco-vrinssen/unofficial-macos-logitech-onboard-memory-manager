#!/bin/sh
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Logitech Onboard Memory Manager"
DEST="${DEST:-$HOME/Applications}"
APP="$DEST/$APP_NAME.app"

swift build -c release --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

install -m 755 "$ROOT/.build/release/LogiOnboardApp" "$APP/Contents/MacOS/OnboardMemory"
install -m 644 "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundleExecutable</key><string>OnboardMemory</string>
	<key>CFBundleIdentifier</key><string>local.marco.onboardmemory</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign ad hoc so Gatekeeper lets a locally built app run
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built $APP"
