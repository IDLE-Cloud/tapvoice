#!/bin/bash
# build-tapvoice.sh: 编译 tapvoice → 打包 TapVoice.app → 自签名（权限绑证书，重编译不失效）
# 用法: ~/bin/build-tapvoice.sh
set -e
BIN=~/bin/tapvoice
APP=~/Applications/TapVoice.app
CERT="TapVoice Dev"

swiftc -O -o "$BIN" ~/bin/tapvoice.swift
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/tapvoice"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TapVoice</string>
  <key>CFBundleExecutable</key><string>tapvoice</string>
  <key>CFBundleIdentifier</key><string>com.user.tapvoice</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

if security find-certificate -c "$CERT" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  codesign --force --sign "$CERT" --timestamp=none "$APP"
  codesign --verify --deep --strict "$APP" && echo "signed+verified: $APP"
else
  echo "WARN: 证书 $CERT 不存在, 先运行: ~/bin/make-tapvoice-cert.sh"
fi
echo "built: $APP"
