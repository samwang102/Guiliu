#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
bundle_dir="$project_dir/Build/归流.app"
info_plist="$bundle_dir/Contents/Info.plist"
icon_file="$bundle_dir/Contents/Resources/AppIcon.icns"

if [[ ! -d "$bundle_dir" ]]; then
    print -u2 "错误：找不到 App Bundle：$bundle_dir"
    exit 1
fi

plutil -lint "$info_plist" >/dev/null

configured_icon="$(plutil -extract CFBundleIconFile raw "$info_plist" 2>/dev/null || true)"
if [[ "$configured_icon" != "AppIcon.icns" ]]; then
    print -u2 "错误：CFBundleIconFile 为 '$configured_icon'，预期为 'AppIcon.icns'。"
    exit 1
fi

if [[ ! -s "$icon_file" ]]; then
    print -u2 "错误：图标未写入 App Bundle：$icon_file"
    exit 1
fi

codesign --verify --deep --strict "$bundle_dir"

signing_info="$(codesign -dvv "$bundle_dir" 2>&1)"
if [[ "$signing_info" == *"Signature=adhoc"* ]]; then
    print -u2 "错误：App 仍使用临时签名，更新后可能重复请求文件访问权限。"
    exit 1
fi

designated_requirement="$(codesign -d -r- "$bundle_dir" 2>&1)"
if [[ "$designated_requirement" == *"cdhash"* ]]; then
    print -u2 "错误：App 的指定要求仍绑定构建哈希，签名身份不稳定。"
    exit 1
fi

print "验证通过：$bundle_dir"
print "图标资源：$icon_file"
print "签名身份：Guiliu Local Code Signing"
print "$designated_requirement"
