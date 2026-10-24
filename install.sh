#!/bin/bash
# magled install — 安装 MagSafe 3 LED 后台守护。
# 用法: sudo sh install.sh   （或在 MagLED 菜单里点"安装后台守护"）
set -euo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "需要管理员权限。请用: sudo sh install.sh"
    echo "（或在 MagLED 菜单栏菜单里点 安装后台守护，按提示输密码即可）"
    exit 1
fi

SELF="$(cd "$(dirname "$0")" && pwd)"

# 1) 找到 helper 二进制：优先本目录，其次 App 包内
HELPER=""
for p in "$SELF/magled-helper" "$SELF/MagLED.app/Contents/Resources/magled-helper" "/Applications/MagLED.app/Contents/Resources/magled-helper"; do
    if [ -f "$p" ]; then HELPER="$p"; break; fi
done
if [ -z "$HELPER" ]; then
    echo "❌ 找不到 magled-helper 二进制（请把整个解压包放在一起）。"
    exit 1
fi

INSTALL_DIR=/usr/local/lib/magled
mkdir -p "$INSTALL_DIR" /var/run
cp "$HELPER" "$INSTALL_DIR/magled-helper"
# 剥离 quarantine 隔离标记（从 GitHub/网盘下载的应用包会带，launchd 执行被隔离的二进制会被 AMFI 杀掉）
xattr -cr "$INSTALL_DIR/magled-helper" 2>/dev/null || true
chmod 755 "$INSTALL_DIR/magled-helper"
codesign -f -s - "$INSTALL_DIR/magled-helper" 2>/dev/null || true

# 2) 旧进程先退
launchctl bootout system/com.atstudio.magled 2>/dev/null || true
pkill -f "$INSTALL_DIR/magled-helper" 2>/dev/null || true

# 3) launchd daemon
PLIST=/Library/LaunchDaemons/com.atstudio.magled.plist
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.atstudio.magled</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/magled-helper</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/var/log/magled.log</string>
    <key>StandardErrorPath</key><string>/var/log/magled.log</string>
    <key>ProcessGroupName</key><string>magled</string>
</dict>
</plist>
EOF
launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl load "$PLIST"

sleep 1
if [ -S /var/run/magled.sock ]; then
    echo "✅ magled 后台守护已安装并运行。"
    echo "   日志: /var/log/magled.log"
    echo "   现在可以用菜单栏 MagLED 或 'ledctl off' 关灯了。"
else
    echo "⚠️  守护已注册，但 socket 未出现，查看 /var/log/magled.log"
    exit 1
fi
