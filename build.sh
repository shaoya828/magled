#!/bin/bash
# build.sh — 编译 probe / ledctl / magled-helper / MagLED.app 并组装发布包。
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build
mkdir -p build/bin

echo "▶ 编译 probe（开发探测）"
xcrun swiftc -O -o build/bin/probe src/SMC.swift src/Fw.swift src/main.swift

echo "▶ 编译 ledctl（命令行工具）"
xcrun swiftc -O -o build/bin/ledctl src/SMC.swift src/Sock.swift src/cli/main.swift

echo "▶ 编译 magled-helper（root 守护）"
xcrun swiftc -O -o build/bin/magled-helper src/SMC.swift src/Sock.swift src/helper/main.swift

echo "▶ 编译 MagLED.app（菜单栏应用）"
APP=build/MagLED.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -target arm64-apple-macos13.0 \
    -framework AppKit -framework ServiceManagement \
    -o "$APP/Contents/MacOS/MagLED" \
    src/SMC.swift src/Sock.swift src/app/LEDModeText.swift src/app/main.swift
cp Info.plist "$APP/Contents/Info.plist"
cp install.sh uninstall.sh "$APP/Contents/Resources/"
cp build/bin/magled-helper "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh "$APP/Contents/Resources/magled-helper"

echo "▶ 生成 App 图标（源设计稿 assets/icon-source.jpg）"
sips -z 1024 1024 assets/icon-source.jpg --out build/AppIcon_1024.png -s format png >/dev/null
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
sips -z 16 16     build/AppIcon_1024.png --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     build/AppIcon_1024.png --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     build/AppIcon_1024.png --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     build/AppIcon_1024.png --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   build/AppIcon_1024.png --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   build/AppIcon_1024.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   build/AppIcon_1024.png --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   build/AppIcon_1024.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   build/AppIcon_1024.png --out "$ICONSET/icon_512x512.png"    >/dev/null
cp build/AppIcon_1024.png "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▶ ad-hoc 签名"
codesign -f -s - build/bin/ledctl
codesign -f -s - build/bin/magled-helper
codesign -f -s - "$APP/Contents/MacOS/MagLED"
codesign -f -s - "$APP"

echo "✅ 构建完成: build/"
ls -la build/bin "$APP/Contents"
