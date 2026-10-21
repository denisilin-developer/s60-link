#!/bin/sh
set -e
cd "$(dirname "$0")"
swift build -c release --product S60Link
APP=build/S60Link.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset
cp .build/release/S60Link "$APP/Contents/MacOS/S60Link"
if [ ! -f build/AppIcon.icns ] || [ AppIcon.svg -nt build/AppIcon.icns ]; then
    swiftc -O -o build/render-icon render-icon.swift
    for s in 16 32 128 256 512; do
        build/render-icon AppIcon.svg build/icon.iconset/icon_${s}x${s}.png $s
        build/render-icon AppIcon.svg build/icon.iconset/icon_${s}x${s}@2x.png $((s * 2))
    done
    iconutil -c icns build/icon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>S60 Link</string>
    <key>CFBundleDisplayName</key><string>S60 Link</string>
    <key>CFBundleIdentifier</key><string>com.denys.s60link</string>
    <key>CFBundleExecutable</key><string>S60Link</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.3</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>S60 Link connects to your Nokia phone over Wi-Fi.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "==> $APP"
