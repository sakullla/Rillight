# macOS 自主播放核心目标机交接

状态（2026-09-26）：macOS 插件、CocoaPods 准备、发行包依赖审计和目标机探针已接入 FFmpeg 自主核心。**当前没有经过验证的 macOS 通用 FFmpeg SDK 或 `librillight_core.dylib` 制品，也没有在 macOS 上构建、启动或播放的结果。** Windows 上的可移植测试仅覆盖清单与像素/时序逻辑。目标 Mac 验证作为未完成的交接事项记录，不阻止当前 workflow 交付；PR CI 的 `macos-handoff` 在缺少输入时明确报告未验证，实际 Mac 打包 job 与 tag 发布必须在缺少输入或校验失败时停止。此缺口不得用 IINA/libmpv 制品填补。

## 固定来源与构建输入

`native/core_dependencies.json` 固定 FFmpeg n9.0.1、补丁、libass 0.17.5 和 dav1d 1.5.3 的源提交。目标 Mac 需从这些来源构建 x86_64+arm64 SDK，包含六个 FFmpeg 共享库、libass、dav1d 和所有非系统传递依赖；FFmpeg 配置须包含 `--enable-libdav1d`，为 AV1 保留软件解码路径。SDK 的 `rillight-core-dependencies.json` 需列出实际配置、来源、每个库的 SHA256、libass 构建依赖及 dav1d 的版本、提交、库路径和哈希。运行时 dylib 必须能在 macOS 12 加载，使用应用内 `@rpath` 闭包，不依赖 Homebrew 或构建机绝对路径。`verify_core_dependencies.py` 负责校验固定来源和清单哈希；`prepare_macos.py` 再校验每个 dylib 的 x86_64/arm64 切片。额外传递库须补齐对应来源和许可材料。

目前仓库提供 Linux x86_64 和 Windows x64 的 SDK 构建器；没有 macOS 通用 SDK 的自动构建器或固定下载制品。取得合格 SDK 后，可在目标 Mac 上构建与当前头文件 ABI 相同的核心：

```sh
python3 packages/rillight_player/native/verify_core_dependencies.py \
  --prefix /absolute/path/to/macos-universal-sdk \
  --target macos-universal --require-subtitles
cmake -S packages/rillight_player/native -B build/macos-core \
  -DRILLIGHT_CORE_PREFIX=/absolute/path/to/macos-universal-sdk \
  -DCMAKE_OSX_ARCHITECTURES='x86_64;arm64' \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0
cmake --build build/macos-core --config Release
export RILLIGHT_MACOS_CORE_PREFIX=/absolute/path/to/macos-universal-sdk
export RILLIGHT_MACOS_CORE_DYLIB="$PWD/build/macos-core/librillight_core.dylib"
export RILLIGHT_MACOS_CORE_SHA256="$(shasum -a 256 "$RILLIGHT_MACOS_CORE_DYLIB" | awk '{print $1}')"
python3 packages/rillight_player/native/prepare_macos.py
```

最后一步在 `packages/rillight_player/macos/Libraries/` 生成可核对的 `rillight-macos-closure.json`；缺少输入、哈希不一致、缺少任一架构或仍含 libmpv 都会失败。请保留 SDK/核心构建日志、源码提交、补丁哈希、依赖清单及每个运行库的许可文本。单独对核心 dylib 提供 SHA256 不能证明其源码来源；需要同时保留构建记录。

## 候选构建、打包与检查

在 macOS 12+ 目标机安装固定的 Flutter 3.47.4、Xcode 和 CocoaPods，保持上述三个环境变量：

```sh
flutter pub get
python3 macos/verify_bundle_test.py
python3 macos/package_dmg_test.py
flutter build macos --release --target lib/main.dart
app="build/macos/Build/Products/Release/rillight.app"
python3 macos/verify_bundle.py "$app"
DYLD_LIBRARY_PATH="$PWD/$app/Contents/Frameworks" \
  python3 macos/probe_core.py "$app" > macos-native-versions.json
python3 macos/sign_bundle.py "$app"
python3 macos/verify_bundle.py --signed "$app"
python3 macos/package_dmg.py "$app" Rillight-macos-test-signed.dmg
```

`bundle_macos.py` 在 Runner 构建阶段重新验证 SDK 与核心，复制并签名清单中的运行库、原始及打包后哈希、来源锁、许可材料。`verify_bundle.py` 检查 bundle 实际字节、x86_64/arm64、macOS 12 部署下限、`@rpath` 闭包、旧 libmpv 排除及最终签名。`probe_core.py` 真实加载 bundle 内核心，核对 ABI、FFmpeg 版本和 dyld 实际库路径；该探针不是视频或音频输出验证。完成签名后，从 Finder 打开安装后的 `.app` 再执行播放用例。请勿创建发布 tag 或将这些命令的配置存在视为执行通过。

## 播放与性能用例

分别在 Intel 与 Apple Silicon 的 macOS 12+ 设备记录通过、失败或未测；每次写明 macOS/Xcode/Flutter 版本、CPU/GPU、显示器、音频输出设备、SDK/核心哈希、媒体编码与样本、实际 decoder、日志和复现步骤。

1. H.264、HEVC、VP9、AV1 的首帧及连续变化帧；内外字幕、色彩范围、高位深、宽高比、旋转和窗口缩放。以本次实际 decoder 状态证实 VideoToolbox 或软件路径。
2. 扬声器与耳机的可听声音；短音轨、暂停恢复、seek、倍速、轨道切换和音画同步。分别记录输出时钟与视频帧进度。
3. 连续开关、播放中退出、全屏切换、睡眠唤醒；检查旧声旧帧、纹理闪烁、崩溃和资源持续增长。
4. 限速、短暂断网及恢复；保持所选画质，检查缓存进度与可播放区间是否一致。记录真实网络条件和服务器是否参与转码。
5. 同一冻结基线与候选在相同设备/媒体/网络下比较首帧、seek 恢复、掉帧、UI/raster 帧耗时和资源占用，保留次数、中位数、p95、波动及失败数据。

实际变化像素、可听音频、硬件 decoder、Finder 启动和 Intel/Apple Silicon 运行均仍为**未验证**。CI 构建、静态清单检查和探针输出应与实体设备播放证据分开记录。
