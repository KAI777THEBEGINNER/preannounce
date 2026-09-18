#!/bin/bash
# 预告（Preannounce）一键构建：编译 → 组装 .app → ad-hoc 签名
# 产物：dist/预告.app
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="预告"           # 目录名用中文：显示名兜底=文件名
BIN_NAME="Preannounce"    # 二进制名保持英文，进程名稳定
APP="$ROOT/dist/$APP_NAME.app"
BUILD="$ROOT/build"

rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 两个二进制，同一份源码，条件编译区分：
#   Preannounce      —— 常驻守护 + CLI 客户端（-D DAEMON，不链接 AppKit，实测物理占用 1.8MB）
#   PreannounceToast —— GUI 胶囊（AppKit），由守护按需拉起，弹完即退
echo "==> 编译 Preannounce（常驻守护，不链接 AppKit）"
for arch in arm64 x86_64; do
    swiftc -O -D DAEMON -target ${arch}-apple-macos26.0 \
        "$ROOT/Sources/main.swift" -o "$BUILD/daemon-$arch" -framework Foundation
done
lipo -create "$BUILD/daemon-arm64" "$BUILD/daemon-x86_64" -output "$APP/Contents/MacOS/$BIN_NAME"

echo "==> 编译 PreannounceToast（GUI 胶囊）"
for arch in arm64 x86_64; do
    swiftc -O -target ${arch}-apple-macos26.0 \
        "$ROOT/Sources/main.swift" -o "$BUILD/toast-$arch" -framework AppKit -framework Foundation
done
lipo -create "$BUILD/toast-arm64" "$BUILD/toast-x86_64" -output "$APP/Contents/MacOS/PreannounceToast"

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>预告</string>
    <key>CFBundleExecutable</key><string>Preannounce</string>
    <key>CFBundleIdentifier</key><string>com.kai.preannounce</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>预告</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" > /dev/null   # plist 写错会让 app 无法签名，这里卡死比后面报错好

echo "==> ad-hoc 签名"
# 不能逐个签 bundle 内的二进制：codesign 会连带校验整个 bundle 的封口，
# 在 bundle 还没签的时候报出误导性的 “code object is not signed at all / In subcomponent”。
# 用 --deep 一次性签完嵌套代码再签 bundle，最后 verify 兜底。
codesign --force --deep -s - "$APP"
codesign --verify --verbose "$APP" 2>&1 | tail -2

echo "==> 完成：$APP"
du -sh "$APP"
codesign -dv "$APP" 2>&1 | head -3
