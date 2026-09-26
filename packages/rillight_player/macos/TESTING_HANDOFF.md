# macOS 播放核心目标机验证交接

状态：macOS 插件的共享核心视频/音频适配源码已准备；**尚未在 macOS 上构建或播放验证**。Windows 上的 C++ 像素与时序测试不能替代以下结果。请在 T8 正式 Dart 后端接入、T10 更新 macOS 打包脚本后执行完整应用测试；在此之前不要用当前应用播放结果判断新核心。

## 准备

- macOS 12 或更新版本；分别记录 Intel 和 Apple Silicon 的结果。安装项目固定的 Flutter 3.47.4、Xcode 与 CocoaPods。
- 准备含 x86_64、arm64 两个架构、libass 及 `rillight-core-dependencies.json` 的 `macos-universal` FFmpeg SDK，以及与当前头文件 ABI 匹配的 `librillight_core.dylib`。T10 应提供固定来源、哈希和构建入口；缺少任一项时记录为“无法验证”，不要回退到 libmpv。
- 在项目根目录运行以下命令，将占位路径换成实际绝对路径：

```sh
python3 packages/rillight_player/native/verify_core_dependencies.py \
  --prefix /absolute/path/to/macos-universal-sdk \
  --target macos-universal --require-subtitles
shasum -a 256 /absolute/path/to/librillight_core.dylib
export RILLIGHT_MACOS_CORE_PREFIX=/absolute/path/to/macos-universal-sdk
export RILLIGHT_MACOS_CORE_DYLIB=/absolute/path/to/librillight_core.dylib
export RILLIGHT_MACOS_CORE_SHA256=<上一步的 SHA256>
flutter pub get
flutter build macos --debug
```

podspec 会校验 SDK 清单、核心库哈希和两种架构切片，然后复制运行时 dylib。`native/bundle_macos.py` 目前仍按旧 libmpv 规则处理发行包；必须在 T10 更新并通过依赖闭包、签名与安装启动检查后，才能称为新核心发行包。

## 目标机用例

在 T8 接入后运行 `flutter run -d macos`，使用有权限的测试 Emby 媒体，逐项记录通过、失败或未测：

1. H.264、HEVC、VP9、AV1 的首帧与连续变化帧；字幕、色彩、宽高比、旋转及窗口缩放。记录每种编码实际选择的软件或 VideoToolbox 路径，不把“设备支持”当成“本次实际硬解”。
2. 内置扬声器和耳机的实际声音；开头很短的音轨、暂停/恢复、seek、倍速、轨道切换，以及视频与声音是否同步。
3. 连续打开/关闭、播放中退出、全屏与窗口切换、系统睡眠/唤醒；观察旧声音、旧帧、崩溃、纹理闪烁与资源持续增长。
4. 限速、短暂断网和恢复；画质保持不自动降低，缓存区间与实际可播放范围一致。该项还依赖 T8 缓存/界面接入。
5. T10 发行构建安装后，从 Finder 启动 `.app`，检查签名、所有 dylib 的架构与 `@rpath` 闭包，并重做至少一次视频和声音用例。

每次记录 macOS/Xcode/Flutter 版本、CPU/GPU、SDK 与核心库哈希、构建日志、测试媒体与操作步骤。视频证据需要显示实际变化帧；声音证据需要注明实际输出设备和可听结果。将模拟器、CI 构建、实体 Mac 播放及硬件解码观察分别记录。若失败，保留控制台日志、崩溃报告和最小复现媒体；不要把未执行项标为通过。
