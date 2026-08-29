#!/bin/bash
# 构建 MacAwake.app（Universal Binary：arm64 + x86_64，ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacAwake"
BUILD_DIR="./dist"
APP="${BUILD_DIR}/${APP_NAME}.app"

echo "==> 编译 Universal Binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64

BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"
if [ ! -f "$BIN" ]; then
  echo "找不到产物: $BIN" >&2
  exit 1
fi

echo "==> 组装 app bundle"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
else
  echo "警告: 缺少 Resources/AppIcon.icns，跑 ./Tools/make-icon.sh 生成" >&2
fi
printf 'APPL????' > "${APP}/Contents/PkgInfo"

echo "==> ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP"

echo "==> 架构确认"
lipo -info "${APP}/Contents/MacOS/${APP_NAME}"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature' || true

echo ""
echo "构建完成: ${APP}"
echo "安装:   cp -R \"${APP}\" /Applications/"
echo "运行:   open \"${APP}\""
