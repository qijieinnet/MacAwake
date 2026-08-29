#!/bin/bash
# 由 Tools/GenerateIcon.swift 重新生成 Resources/AppIcon.icns
# 图标是代码画的，改完设计跑一次这个脚本即可
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 编译生成器"
swiftc -O Tools/GenerateIcon.swift -o "$TMP/gen"

echo "==> 渲染各尺寸"
"$TMP/gen" "$TMP"

echo "==> 合成 icns"
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$TMP/icon-1024.png" docs/app-icon.png

echo "完成: Resources/AppIcon.icns  ($(du -h Resources/AppIcon.icns | cut -f1))"
