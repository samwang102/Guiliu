# 归流 App 图标源文件

最终图标的 1024×1024 PNG 位于本目录，并命名为：

`AppIcon-1024.png`

图形以“散落文件流入有序归档盒”为核心意象，并采用蓝绿主色与珊瑚色流向标记。打包使用同目录下由这张源图生成并校验过的 `AppIcon.icns`。脚本会用 macOS 自带的 `iconutil` 解包验证它，再写入 App Bundle。保留 ICNS 是为了兼容部分 `iconutil` 版本无法稳定转换有效 iconset 的问题。

本目录图标为归流项目原创资产；除非另有说明，随仓库使用与项目根目录 `LICENSE` 相同的许可证发布。

源图要求：

- PNG 格式。
- 尺寸必须为 1024×1024。
- 保留透明通道或使用完整的方形背景均可；视觉安全边距应在设计源图中处理。

打包与验证：

```zsh
swift build -c release --disable-sandbox
./Distribution/package_app.sh
./Distribution/verify_app.sh
```
