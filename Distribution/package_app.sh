#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
bundle_dir="$project_dir/Build/归流.app"
app_binary="$(swift build -c release --disable-sandbox --show-bin-path)/Guiliu"
icon_source="$project_dir/Resources/AppIcon/AppIcon-1024.png"
icon_prebuilt="$project_dir/Resources/AppIcon/AppIcon.icns"
icon_output="$bundle_dir/Contents/Resources/AppIcon.icns"
signing_identity="${GUILIU_CODESIGN_IDENTITY:-Guiliu Local Code Signing}"

if [[ ! -f "$icon_source" ]]; then
    print -u2 "错误：缺少 App 图标源文件：$icon_source"
    print -u2 "请放入 1024×1024 PNG 后重新打包。"
    exit 1
fi

if [[ ! -x "$app_binary" ]]; then
    print -u2 "错误：缺少 release 可执行文件：$app_binary"
    print -u2 "请先运行 swift build -c release --disable-sandbox。"
    exit 1
fi

icon_format="$(sips -g format "$icon_source" | awk '/format/ { print $2 }')"
icon_width="$(sips -g pixelWidth "$icon_source" | awk '/pixelWidth/ { print $2 }')"
icon_height="$(sips -g pixelHeight "$icon_source" | awk '/pixelHeight/ { print $2 }')"
if [[ "$icon_format" != "png" || "$icon_width" != "1024" || "$icon_height" != "1024" ]]; then
    print -u2 "错误：App 图标必须为 1024×1024 PNG，当前为 ${icon_format:-?} ${icon_width:-?}×${icon_height:-?}。"
    exit 1
fi

if [[ ! -s "$icon_prebuilt" ]]; then
    print -u2 "错误：缺少预生成 App 图标：$icon_prebuilt"
    exit 1
fi

# Validate that macOS can read the checked-in multi-resolution icon. Some
# iconutil versions reject valid iconsets during conversion, so packaging
# validates by decoding and then uses the prebuilt file.
icon_validation_dir="$(mktemp -d "${TMPDIR:-/tmp}/guiliu-icon.XXXXXX")"
trap 'rm -rf "$icon_validation_dir"' EXIT
iconutil -c iconset "$icon_prebuilt" -o "$icon_validation_dir/AppIcon.iconset"
test -n "$(find "$icon_validation_dir/AppIcon.iconset" -type f -name '*.png' -print -quit)"

mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
cp "$project_dir/Distribution/Info.plist" "$bundle_dir/Contents/Info.plist"
cp "$app_binary" "$bundle_dir/Contents/MacOS/Guiliu"
cp "$icon_prebuilt" "$icon_output"
chmod +x "$bundle_dir/Contents/MacOS/Guiliu"

if ! security find-identity -v -p codesigning | grep -Fq "\"$signing_identity\""; then
    print -u2 "错误：找不到稳定代码签名身份：$signing_identity"
    print -u2 "为保持 macOS 文件访问权限身份稳定，打包流程禁止使用临时签名。"
    exit 1
fi

codesign --force --deep --options runtime --timestamp=none --sign "$signing_identity" "$bundle_dir"

plutil -lint "$bundle_dir/Contents/Info.plist" >/dev/null
test -s "$icon_output"
codesign --verify --deep --strict "$bundle_dir"

echo "$bundle_dir"
