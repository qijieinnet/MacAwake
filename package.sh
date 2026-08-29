#!/bin/bash
# 从 dist/MacAwake.app 生成可分发的 DMG
#   MacAwake-Universal.dmg  同时支持 Apple Silicon 与 Intel（推荐）
#   MacAwake-arm64.dmg      仅 Apple Silicon，体积更小
#   MacAwake-x86_64.dmg     仅 Intel
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacAwake"
SRC_APP="dist/${APP_NAME}.app"
OUT="dist"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${SRC_APP}/Contents/Info.plist")}"

[ -d "$SRC_APP" ] || { echo "找不到 ${SRC_APP}，先跑 ./build.sh" >&2; exit 1; }

make_dmg() {
  local arch="$1" label="$2"
  local stage="${OUT}/stage-${label}"
  local app="${stage}/${APP_NAME}.app"

  rm -rf "$stage"; mkdir -p "$stage"
  cp -R "$SRC_APP" "$app"

  if [ "$arch" != "universal" ]; then
    # 从通用二进制里抽出单一架构，减小体积
    local bin="${app}/Contents/MacOS/${APP_NAME}"
    lipo -thin "$arch" "$bin" -output "${bin}.thin"
    mv "${bin}.thin" "$bin"
  fi

  # 抽取架构后签名会失效，重新做 ad-hoc 签名
  codesign --force --sign - --timestamp=none "$app"

  local archs
  archs=$(lipo -archs "${app}/Contents/MacOS/${APP_NAME}")

  # 拖到「应用程序」的快捷方式
  ln -s /Applications "${stage}/Applications"

  local dmg="${OUT}/${APP_NAME}-${VERSION}-${label}.dmg"
  rm -f "$dmg"
  hdiutil create -volname "${APP_NAME}" -srcfolder "$stage" \
    -ov -format UDZO -quiet "$dmg"
  rm -rf "$stage"
  echo "  $(basename "$dmg")  $(du -h "$dmg" | cut -f1)  [${archs}]"
}

echo "==> 打包 v${VERSION}"
make_dmg universal Universal
make_dmg arm64     arm64
make_dmg x86_64    x86_64
echo "完成，产物在 ${OUT}/"
