#!/usr/bin/env bash
#
# 从原始立绘生成 App 的全部图像资源（图标 + 内置背景）。
#
# 设计原则：**只用原图，不做抠图/合成/加装饰**。
# 本脚本仅做「缩放」与「用原图自身的黑底补足竖屏高度」两件事，
# 保证产物与用户提供的立绘在观感上完全一致。
#
# 用法：
#   bash tools/render-assets.sh
#
# 依赖：ImageMagick 7（convert）、原图 assets/branding/source.jpg
#
# ⚠️ 图标与背景都是**生成产物**，不要手工编辑；
#    要改外观就改原图，然后重跑本脚本。

set -euo pipefail

cd "$(dirname "$0")/.."   # 切到 app/ 根目录

SRC="assets/branding/source.jpg"
RES="android/app/src/main/res"

if [[ ! -f "$SRC" ]]; then
  echo "✗ 找不到原图：$SRC" >&2
  exit 1
fi

if ! command -v convert >/dev/null 2>&1; then
  echo "✗ 需要 ImageMagick（apt-get install -y imagemagick）" >&2
  exit 1
fi

echo "原图：$(identify -format '%wx%h' "$SRC")"

# ── 1. 应用图标（传统 mipmap，五个密度）─────────────────────────────
# 直接缩放原图，不做任何裁剪或抠图。
echo
echo "生成图标："
declare -A ICON_SIZES=(
  [mdpi]=48 [hdpi]=72 [xhdpi]=96 [xxhdpi]=144 [xxxhdpi]=192
)
for density in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  size="${ICON_SIZES[$density]}"
  out="$RES/mipmap-$density/ic_launcher.png"
  convert "$SRC" -resize "${size}x${size}" -strip "$out"
  echo "  mipmap-$density/ic_launcher.png  ${size}x${size}  $(stat -c%s "$out") 字节"
done

# 自适应图标（mipmap-anydpi-v26）**故意不生成**：
# 它要求前景内容限制在中心 66/108 的安全区，系统还会按设备裁成圆形/方形，
# 那会把原图的构图裁掉。传统图标能完整显示原图，故选它。

# ── 2. 内置背景（竖屏）──────────────────────────────────────────
# 原图是 1:1 方形且自带纯黑底；竖屏需要更长，
# 于是按宽度铺满、垂直居中，上下用原图自身的黑底色补足 —— 视觉上无缝。
echo
echo "生成背景："
BG_OUT="assets/backgrounds/app_bg.jpg"
convert "$SRC" -resize 1080x -strip \
  -background "#09080B" -gravity center -extent 1080x2400 \
  -quality 92 "$BG_OUT"
echo "  assets/backgrounds/app_bg.jpg  1080x2400  $(stat -c%s "$BG_OUT") 字节"

echo
echo "✓ 完成。别忘了：图标/背景变了要重新构建 APK 才生效。"
