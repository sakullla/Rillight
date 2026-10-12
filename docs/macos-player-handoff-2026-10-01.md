# macOS 播放器适配交接

## macOS 构建步骤

要求 macOS 12+、Flutter 3.47.6、Xcode/CMake/Python，以及固定来源的 x86_64+arm64 SDK。构建 inputs 和依赖闭包规范见 [播放器 README](../packages/rillight_player/README.md)。示例从仓库根运行：

```sh
git rev-parse HEAD
flutter --version
flutter pub get
python3 macos/verify_bundle_test.py

# 根据自己的磁盘位置修改这两个绝对路径。
export RILLIGHT_MACOS_CORE_PREFIX="$PWD/build/macos-universal-sdk"
packages/rillight_player/native/build_macos.sh \
  "$RILLIGHT_MACOS_CORE_PREFIX" "$PWD/build/macos-core-source"
python3 packages/rillight_player/native/verify_core_dependencies.py \
  --prefix "$RILLIGHT_MACOS_CORE_PREFIX" \
  --target macos-universal --require-subtitles
cmake -S packages/rillight_player/native -B build/macos-core \
  -DRILLIGHT_CORE_PREFIX="$RILLIGHT_MACOS_CORE_PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES='x86_64;arm64' \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_BUILD_TYPE=Release
cmake --build build/macos-core --config Release
export RILLIGHT_MACOS_CORE_DYLIB="$PWD/build/macos-core/librillight_core.dylib"
export RILLIGHT_MACOS_CORE_SHA256="$(shasum -a 256 "$RILLIGHT_MACOS_CORE_DYLIB" | awk '{print $1}')"
python3 packages/rillight_player/native/prepare_macos.py
flutter build macos --release --target lib/main.dart
python3 macos/verify_bundle.py build/macos/Build/Products/Release/rillight.app
```

输出几何与调度的原生回归可独立跑：

```sh
cmake -S packages/rillight_player/native/core_tests/macos \
  -B build/macos-frame-tests
cmake --build build/macos-frame-tests
ctest --test-dir build/macos-frame-tests --output-on-failure
```

实际启动必须使用本次打包 `.app`，记录核心/FFmpeg 实际加载路径、版本、架构、哈希和 decoder。保留来源/签名/闭包检查结果；无需更换到 libmpv 或 Media3。登录 UA 来自已保存配置，不硬编码、不伪造。

## macOS 适配优先级

### 1. 先闭合基本播放与生命周期

原生入口位于 `packages/rillight_player/macos/rillight_player/Sources/rillight_player/`：`RillightPlayerPlugin.mm` 负责 VideoToolbox 偏好、音视频队列和 FlutterTexture 发布；`FrameOutput.h` 适配 RGBA→BGRA、旋转、SAR 和视口；`FrameTiming.h` 管理时间；`CoreAudioOutput.h` 管理实际音频输出。

先验证 H.264/HEVC/AV1/VP9、有声/无声/纯音频。播放中暂停、前后跳转、续播、切字幕/音轨、变速、换源和下一集；连续反复开关窗口，后台恢复，全屏、resize、跨屏。各操作检查会话/时间线正确、队列有界、旧帧不复活、音视频不停止、资源释放。读取 actual_hardware，VideoToolbox 配置成功不代表已实际硬解。

### 2. 真正 HDR / 杜比视界

当前插件创建 `kCVPixelFormatType_32BGRA` 的 CVPixelBuffer，经 immutable IOSurface 发布 Flutter 纹理；`FrameOutput.h` 只接受 `RILLIGHT_CORE_VIDEO_RGBA`。8 位转换完成后无法恢复 HDR 高亮。需要设计原生 EDR 输出及高精度帧契约，检查 Metal/CAMetalLayer 的像素格式、色彩空间和屏幕 EDR headroom，避免中途经过 SDR 8 位纹理。Windows FP16/scRGB 管线仅提供设计参考。

必须统一 PQ/HLG/线性颜色变换、色域、SDR 白基准、字幕与 UI 的亮度；正确处理屏幕切换、HDR 能力变化、窗口大小/全屏和加载黑底。无 HDR 屏时输出可用的 SDR 映射。保留 Impeller 开启。

杜比视界需要按实际 profile、compatibility ID、RPU 与基础层逐样本确认。区分“基础层可以显示”“正确处理动态元数据”和“真正 HDR 输出”。不要只把所有 DV 当普通 HEVC；也不要仅凭能解码或诊断显示 HDR 就宣布支持。准备 Profile 5/8 等实际样本，对照色彩、高亮和帧率；不支持的组合给明确可恢复结果。

### 3. 60fps 呈现与弹幕

记录片源真实帧率、decode/convert/output 耗时、队列深度、丢帧与实际显示节奏。60fps 预算约 16.67ms；需要连续变化的实际显示帧证据，不能以 position 前进、首帧事件或 60Hz 配置代替。重点检查 `FrameOutput.h` 每帧 CPU resize/copy 与 IOSurface 分配成本，再按测量结果优化；不能只扩大超时或忽略解码慢。

同一 60fps 样本分别测 SDR、HDR10、DV，1×、1.25×和 2×，窗口与全屏；用密集长句弹幕和固定弹幕复测。控制栏显隐、显示器切换时观察白色填充、描边与字幕合成是否变化。捕获应限制在应用窗口；HDR backing/EDR 合成未被捕获时要说明，截图黑色区域不能直接认定无画面。

### 4. 杜比音频

FFmpeg 当前做 E-AC-3/TrueHD 等解码和 PCM 输出/声道处理。**PCM 可听不等于 Atmos 对象渲染，也不等于压缩直通。** 分别记录解码能力、CoreAudio 实际设备/声道、物理扬声器/耳机声音与同步。若要支持多声道或 HDMI 压缩直通，应单独确定设备协商和输出契约；不得用虚拟音频或波形代替物理听感。


## 验收要求

按 [目标系统交接](../packages/rillight_player/macos/TESTING_HANDOFF.md) 验证构建、签名、依赖闭包、实际窗口画面、物理声音与解码器。设备路径、个人环境和运行记录保存到忽略的证据目录，不在仓库文档中列出。
