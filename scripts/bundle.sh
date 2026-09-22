#!/usr/bin/env bash
# Builds Pencil in release mode and assembles an ad-hoc signed build/Pencil.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Render the app icon (Resources/AppIcon.icns + Resources/icon-preview.png).
"$ROOT/scripts/make-icon.sh"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Pencil"

APP="$ROOT/build/Pencil.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pencil"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

VERSION="1.0"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>Pencil</string>
    <key>CFBundleDisplayName</key>          <string>Pencil</string>
    <key>CFBundleIdentifier</key>           <string>com.haim.pencil</string>
    <key>CFBundleExecutable</key>           <string>Pencil</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>${VERSION}</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>LSUIElement</key>                  <true/>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSPrincipalClass</key>             <string>NSApplication</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Pencil captures the screen, including your drawings, when you take a snapshot (Control-Option-S) so you can paste it into another app.</string>
    <key>NSHumanReadableCopyright</key>     <string>Pencil screen annotation tool.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Sign with the stable local identity when it exists (see scripts/make-signing-identity.sh):
# the designated requirement then stays the same across rebuilds, so the Screen Recording
# grant keeps working. Otherwise fall back to ad-hoc (the grant breaks on every rebuild).
IDENTITY="Pencil Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --deep --sign "$IDENTITY" --identifier com.haim.pencil "$APP"
else
    echo "warning: \"$IDENTITY\" not found; signing ad-hoc. Run scripts/make-signing-identity.sh once." >&2
    codesign --force --deep --sign - --identifier com.haim.pencil "$APP"
fi
codesign --verify --verbose=1 "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true

# Nudge Finder/Spotlight to pick up the new icon.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "Built $APP"
