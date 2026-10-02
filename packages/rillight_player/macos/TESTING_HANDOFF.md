# macOS 自主播放核心目标机交接

## 2026-10-01 Android 自有 GPU 管线后续候选

共用 ABI 8 头文件已同步 additive external-audio-speed API。默认关闭，macOS 的 atempo 和音频时钟语义保持原路径；macOS 适配若启用，必须由音频 sink 实施保音高调速，报告源 PCM 的媒体时长，不能再乘 rate。公开结构布局未改。

Android 无原生 Profile 5 codec 时现在使用真实 HEVC MediaCodec + P010/RPU + 自有 GLES3，具备条件时输出 10 位 BT.2020 PQ；该 GLES 呈现仅编译进 Android，不是 macOS EDR 实现。当前手机短窗口 HDR60 与杜比倍速/重挂载已有变化画面，但长 GOP forward seek 仍约 2.3 秒预解码，组合检查整体失败，物理 HDR/声音及持续性能仍未验收。最新候选与失败证据见 [Android 播放记录](../../../docs/android-player-ui-2026-10-01.md)。

本轮未运行 macOS 构建、GUI、VideoToolbox、物理音频或 EDR 验证；目标机须按下方协议单独验证。以下早期交接和历史记录保留其当时范围。

## 2026-10-01 播放器与界面候选交接

本轮 Windows 工作区的实现、验证结果、构建命令和目标机适配顺序见 [macOS 播放器交接](../../../docs/macos-player-handoff-2026-10-01.md)。候选为包含该文档的提交，基准 `ea12d3a`。Swift Package 的核心头文件已同步 ABI 8；当前 macOS 仍发布 8 位 BGRA Flutter 纹理，真正 EDR/HDR 输出尚待实现。共用核心包含 1×音频过滤优化与 Android MediaCodec 恢复修改；本轮没有执行 macOS 原生编译、GUI 帧、物理音频或 VideoToolbox 实际路径验收。Android 已补做真机重试并修复传输 isolate 退出：基本原生检查通过，但杜比倍速/seek 后的变化画面检查失败；真正 HDR、实际 60fps 和物理音频仍未验收，详细结果见交接文档新增章节。以下历史记录保持原有证据边界。

## 2026-09-28 音视频流水线分离待目标机验证

共用核心将解封装、音频解码/过滤、视频解码/转换、字幕解码拆成有界队列连接的工作线程。跳转、音轨/字幕切换和变速先清空旧时间线并等待正在执行的解码退出，再修改解码器。macOS 的音频供给改用独立 GCD 串行队列和定时器，视频转换、IOSurface 提交及纹理通知保留在视频队列；两者只交换带会话/时间线的启动与排空状态。detach 等待两个队列清理后才允许释放核心。

本次在 Windows 修改，**尚未在 macOS 编译或验收**。需在目标机重新构建并检查：有声视频/纯音频/无声视频、暂停与跳转、切轨和变速、播放结束、反复开关窗口、慢画面提交时声音连续；分别记录真实变化帧、物理音频和 VideoToolbox 路径。此修改未实现或验证杜比全景声/杜比视界。

状态（2026-09-26，Apple M3 / macOS 27.0）：已在本机从固定源构建 x86_64+arm64 FFmpeg SDK 与 `librillight_core.dylib`，完成 CocoaPod 准备、Release `.app` 依赖审计、核心探针、adhoc 签名、测试 DMG 和沙箱代理。**Finder 启动后的 H.264/HEVC/VP9/AV1 连续变化帧、扬声器/耳机可听声音、VideoToolbox 实际 decoder 路径、Intel 机型，以及限速/断网/性能对照仍为未验证。** 本记录不得当作五平台发行通过；tag 发布仍须固定 SDK/核心输入。此缺口不得用 IINA/libmpv 制品填补。

## 2026-09-27 用户反馈与 HLS 后续复测

CI 配置更新：PR/main 在四个预编译输入全部未配置时，从仓库固定源构建 universal SDK，并编译当前候选核心；部分配置或校验失败直接报错。`macos-native-inputs` 制品保存 SDK/core、SHA256 和构建上下文。tag 仍要求四个固定输入，不允许源码回退。托管 runner 配置运行沙箱代理与合成媒体播放控制回归，显式禁用屏幕捕获，并在 `validation-scope.json` 区分控制结果、画面、物理声音和硬件验收。**这段描述是工作流配置，不是新一轮已执行的 macOS 或实体设备验证；下文历史结果不因此升级。**

用户已在自己的 macOS 电脑实际试用，反馈：**“已测试，除了HLS有点卡其他没大问题”**。这补充了人工使用结果；本次反馈未提供媒体/编码清单、所选码率、网络条件、卡顿次数或解码器诊断，因此不能据此补齐下文的逐编码变化帧、VideoToolbox、物理声音或 Intel 验收。下文 2026-09-26 环境及脚本记录是历史测量；已合并的 `f39b797` 构建与 Dart 控制路径证据也不等于所有 GUI/声音用例通过。

共享 HLS 代理已在 Windows 的受控 HTTP 回归中复现一个调度等待：当前分段正文被闸门暂停时，旧实现直到整段结束才请求下一段。`test/player/hls_prefetch_test.dart` 的下一段请求检查在旧逻辑下 1 秒超时；修复后，在当前段仍未结束时即可获取下一段。只提前预取已选 VOD 列表的下一个分段，仍保持单个预取生产者、总请求上限和前台请求余量。前台请求命中正在预取的同一资源时最多等 100ms 让其完成缓存发布，随后可抢占，避免等待后台网络超时。已完成的预取不重复下载；未完成且超出该等待窗口的预取会取消并由前台重取，不声称所有部分下载都能复用。

这些回归检查请求顺序、缓存复用、停滞预取时当前段继续完成、seek 取消及 503 恢复，**不证明用户 macOS 卡顿的根因或修复后的实际流畅度**。实现不自动切换画质，也不并行请求全部变体。协议依据：[RFC 8216 §6.3.2/§6.3.5/§10](https://www.rfc-editor.org/rfc/rfc8216.html) 对当前 rendition、下一段顺序及合理并发的约束；具体调度仍以应用测试为准。

目标机复测请使用同一 HLS 媒体、所选画质及相同网络条件，对比修复前后：

1. 记录首帧时间、连续播放的卡顿次数/总时长、上游吞吐和请求状态，以及下一段是否与当前段下载重叠；不要记录鉴权头或含凭据的媒体 URL。
2. 在限速和短暂断网恢复后，检查保持所选画质、进度持续前进；向前/向后 seek，确认取消旧预取后目标段可及时读取。
3. 单独记录实际画面、实际 decoder 和扬声器/耳机声音；这些证据不能由 Dart 请求顺序测试代替。若仍卡顿，保留同一时段的分段网络/缓存状态与核心状态，再区分传输和解码/输出原因。

## 本机环境（2026-09-26 历史记录）

| 项 | 值 |
| --- | --- |
| 主机 | yanggengdeMacBook-Air.local |
| CPU | Apple M3（arm64） |
| 显示器 / 音频 | 未记录；GUI 播放用例未跑 |
| macOS | 27.0 (26A428) |
| Xcode | 27.0 (27A266a) |
| Flutter | 3.47.4 stable |
| CMake | 4.4.3 |
| Python（构建） | 3.14.7 |
| Python（Xcode 脚本） | /usr/bin/python3 3.9.6 |
| Git | `95e00f7d7f4085d21f08e483ee256147159db827` 加上本机未提交的 macOS 构建器与打包修复 |

Intel macOS 12+：**未测**。

## 固定来源与构建输入

`native/core_dependencies.json` 现固定 FFmpeg n9.0.2、补丁、libass 0.17.5 和 dav1d 1.5.3。此前本机 n9.0.1 构建与测试结果仍是历史记录，尚未验证 n9.0.2 的 macOS 实体播放。macOS 字幕依赖复用同一文件中的 FreeType 2.13.3、FriBidi 1.0.16、HarfBuzz 10.4.0 源钉，静态链入 `libass`，字体提供者为 CoreText。FFmpeg 配置含 `--enable-libdav1d`、`--enable-videotoolbox`、`--enable-network`、`--disable-autodetect`。运行库使用 `@rpath` 与 `@loader_path`，部署下限 macOS 12.0。

仓库现在提供构建器：

```sh
packages/rillight_player/native/build_macos.sh \
  /absolute/path/to/macos-universal-sdk \
  /absolute/path/to/macos-core-source
```

随后：

```sh
python3 packages/rillight_player/native/verify_core_dependencies.py \
  --prefix /absolute/path/to/macos-universal-sdk \
  --target macos-universal --require-subtitles
cmake -S packages/rillight_player/native -B build/macos-core \
  -DRILLIGHT_CORE_PREFIX=/absolute/path/to/macos-universal-sdk \
  -DCMAKE_OSX_ARCHITECTURES='x86_64;arm64' \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build/macos-core --config Release
export RILLIGHT_MACOS_CORE_PREFIX=/absolute/path/to/macos-universal-sdk
export RILLIGHT_MACOS_CORE_DYLIB="$PWD/build/macos-core/librillight_core.dylib"
export RILLIGHT_MACOS_CORE_SHA256="$(shasum -a 256 "$RILLIGHT_MACOS_CORE_DYLIB" | awk '{print $1}')"
python3 packages/rillight_player/native/prepare_macos.py
```

`prepare_macos.py` 在 `packages/rillight_player/macos/Libraries/` 生成 `rillight-macos-closure.json`，并去掉核心 dylib 的构建机绝对 rpath。缺少输入、哈希不一致、缺少任一架构或仍含 libmpv 都会失败。单独对核心 dylib 提供 SHA256 不能证明其源码来源；需要同时保留构建记录。

本次实际前缀：

- SDK：`build/macos-core-sdk`（工作树忽略目录）
- 源码工作区：`build/macos-core-source`
- 构建日志：`build/macos-sdk-build.log`

## 本次制品哈希

| 制品 | SHA256 |
| --- | --- |
| `rillight-core-dependencies.json` | `8806cfcdc97e89457e8d5a84f361e8a9a98f3ed8c23e9ca8e3b6d165e920b677` |
| `librillight_core.dylib`（CMake 输出） | `a5ba8114a9be12456a12f12499cb650a231b4dac9819cf1d8c0904e3c8e236c6` |
| 暂存后 `librillight_core.dylib`（已改写 rpath） | `87071714b82cc843ba31b488ef912c5375a18c94fa3438ad0433e40c69796eaf` |
| `libavcodec.63.dylib` | `57f1adab80fd5328a34698052b0adbe4b8112d5d0e98d59457f6080d3b2bf5c8` |
| `libavformat.63.dylib` | `8a66de407337e7aac7dce5330af0217f3192635a4cad3715c45916118936f4e2` |
| `libavutil.61.dylib` | `8d5569a92d5e6065fa3a9d0f327d7a35347a33d3b6bc40e0328eb636ba77580d` |
| `libavfilter.12.dylib` | `950851bd3c6055000839f26c050e2484dce0d5073a64cf214a8d36f643c8ea1e` |
| `libswresample.7.dylib` | `3f8144a952a94132c17781858b408e6d8665d19835f727c94d21bfbcf43247fa` |
| `libswscale.10.dylib` | `8c446eef35535e0df2f6b538ef2990935d45b8b4460e88638a204687b37acc82` |
| `libass.9.dylib` | `dc6986e97f6bdf86ee5863b3b559108e2fd3872b1092cc68742283ac447d792e` |
| `libdav1d.7.dylib` | `e3cb21b12d3700b33473f6a9cb547912435d7f6890a99ac556acc69294249865` |
| `libavdevice.63.dylib`（本次多余运行库） | `ec17fd6d7e1319e1aa8d8352b40b8f2b9fd46be66f260d052ee5f37174625a62` |
| adhoc 测试 DMG | `a3ecb6dcfa1d24259521f056ffeeeb2c34558d0c10493553d9984a10af2d3237` |

FFmpeg 提交 `bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa`（n9.0.1），核心 ABI 8。所有列出的 dylib 均为 `x86_64 arm64`，`minos 12.0`。`otool -L` 仅见 `@rpath/`、`/usr/lib/` 与 `/System/Library/`。探针加载了除 `libavdevice` 外的全部打包库；`libavdevice` 已哈希进闭包但未被 dyld 拉起。后续构建器已加入 `--disable-avdevice`，下一次重编 SDK 将去掉该库。

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

像素/时序逻辑（不依赖 SDK）：

```sh
cmake -S packages/rillight_player/native/core_tests/macos -B build/macos-frame-output
cmake --build build/macos-frame-output
ctest --test-dir build/macos-frame-output --output-on-failure
```

`bundle_macos.py` 在 Runner 构建阶段重新验证 SDK 与核心。`verify_bundle.py` 检查 bundle 实际字节、双架构、macOS 12 部署下限、`@rpath` 闭包、旧 libmpv 排除及最终签名。`probe_core.py` 真实加载 bundle 内核心；该探针不是视频或音频输出验证。请勿创建发布 tag 或将配置存在视为播放通过。

### 本机已执行结果

| 检查 | 结果 |
| --- | --- |
| `build_macos.sh` 通用 SDK | 通过；`verify_core_dependencies.py --require-subtitles` 通过 |
| `librillight_core.dylib` 通用构建 | 通过 |
| `rillight_core_audio_session` | 通过（4.77s） |
| `rillight_core_ass_composition` | **失败**：`ass_test.cpp:515` 等待慢速外部 ASS 在 9s 内结束 pending；CoreText 已选用 Helvetica。嵌入 ASS 路径有日志，该慢 IO 用例未过 |
| `rillight_macos_frame_output` | 通过 |
| `macos/verify_bundle_test.py` | 通过 |
| `flutter build macos --release --target lib/main.dart` | 通过，`rillight.app` 111.6MB |
| `verify_bundle.py` / `--signed` | 通过（15 个 Mach-O，10 个通用核心 dylib） |
| `probe_core.py` | 通过；ABI 8，FFmpeg n9.0.1；证据 `build/macos-native-versions.json` |
| 沙箱代理 `macos/proxy_smoke.py` | 通过；`build/macos-proxy-sandbox-evidence/result.json` |
| adhoc `sign_bundle.py` + 测试 DMG | 通过；`build/Rillight-macos-test-signed.dmg` |
| `open` 启动 Release `.app` | 进程出现后结束；未进入播放页 |
| `macos/player_smoke.py` | Dart 控制路径通过，证据 `build/player-validation/macos-runs/20260926-235827`：H.264/HEVC/VP9/HLS `videotoolbox`，AV1 `software`（dav1d）；seek/暂停/字幕/HLS 均完成。`result.json` `passed: true`。窗口 PNG 因 Python 无屏幕录制权限失败（`could not create image from display`）。扬声器未测 |
| 切集黑屏 | 已修：macOS 纹理 `dispose` 等待 Impeller `onTextureUnregistered` 会挂死；改为 Linux 同款 detach + raster barrier |

Xcode 打包脚本使用系统 Python 3.9。`verify_core_dependencies.py` / `prepare_macos.py` / `bundle_macos.py` 需 `from __future__ import annotations`，否则 `X \| Y` 注解会在 PhaseScriptExecution 失败。

## 播放与性能用例

分别在 Intel 与 Apple Silicon 的 macOS 12+ 设备记录通过、失败或未测；每次写明 macOS/Xcode/Flutter 版本、CPU/GPU、显示器、音频输出设备、SDK/核心哈希、媒体编码与样本、实际 decoder、日志和复现步骤。

1. H.264、HEVC、VP9、AV1 的首帧及连续变化帧；内外字幕、色彩范围、高位深、宽高比、旋转和窗口缩放。以本次实际 decoder 状态证实 VideoToolbox 或软件路径。
2. 扬声器与耳机的可听声音；短音轨、暂停恢复、seek、倍速、轨道切换和音画同步。分别记录输出时钟与视频帧进度。
3. 连续开关、播放中退出、全屏切换、睡眠唤醒；检查旧声旧帧、纹理闪烁、崩溃和资源持续增长。
4. 限速、短暂断网及恢复；保持所选画质，检查缓存进度与可播放区间是否一致。记录真实网络条件和服务器是否参与转码。
5. 同一冻结基线与候选在相同设备/媒体/网络下比较首帧、seek 恢复、掉帧、UI/raster 帧耗时和资源占用，保留次数、中位数、p95、波动及失败数据。

**本机（Apple Silicon）**：合成夹具脚本已跑通 H.264/HEVC/VP9 的 VideoToolbox 与 AV1 软件路径、seek、字幕和 HLS。窗口 PNG 与扬声器仍未取得。Finder 安装后的人工播放、Intel 未测。

CI 构建、静态清单检查和探针输出应与实体设备播放证据分开记录。

## 2026-10-01 共享杜比色彩路径变更（待目标机验证）

原生核心新增 `PortableColorPipeline`，Profile 5 的逐帧 RPU 处理不再仅限
Windows。CPU 路径在 YUV 16 bit 精度下完成缩放后进行 polynomial/MMR reshaping、
PQ、RPU 矩阵、BT.2020 色域转换和 SDR 映射，使用查找表和持久工作线程。
VideoToolbox 下载帧仍需保留逐帧 side data。

此项没有在 macOS 实际构建或播放。需要在 Intel 和 Apple Silicon 上重跑
`rillight_portable_color_pipeline`，验证真实 Profile 5/8 的变化彩色画面、
seek/倍速、字幕和退出/睡眠恢复，并记录实际 VideoToolbox 或软件解码器。
现有 Flutter BGRA 纹理仍输出 SDR；Metal/EDR 原生 HDR 显示尚未接通。

## 2026-10-01 原生 macOS 基础输出适配（工作树）

本次对象为 `0150f7912b9957e4ae2500845ef19360e2162414` 加未提交的 macOS 输出改动，
不是历史 n9.0.1 `.app`。主机 macOS 27.0（26A428），Flutter 3.47.4 / Dart 3.13.3。
操作期间执行权限变为受限沙箱；后续原生系统服务、用户目录写入及本地 socket
检查须按失败或未验证记录，不能沿用之前的应用验收结论。

### 实现与诊断

- 暂停 open/seek 的预览不再等待一个不会前进的播放时钟。回归先在旧逻辑上
  触发断言失败，修复后通过；播放中的提前呈现窗口由 33ms 收紧为 10ms。
- `WriteBgra` 直接写入有 stride 的目标，保留 SAR、旋转、黑边及 alpha；
  `PixelBufferOutput` 在无需几何适配时使用 Accelerate 的 RGBA→BGRA 转换。
  移除每帧中间 BGRA vector 和随后整帧 memcpy，仍保留独立、不可变 IOSurface。
- 不复用已发布的 pixel buffer：本次 SDK 内 Flutter 引擎在纹理桥接后释放
  CVPixelBuffer/CVMetalTexture 包装，不能仅凭其引用计数推断 GPU 已结束采样。
  未加入没有 GPU 完成证据的纹理池。
- 待处理的主线程纹理通知合并为至多一个。发布失败保留重试状态，未发布的末帧
  不报告 output drained；会话/时间线改变仍释放旧帧并清空输出状态。
- `status` 新增 `textureCopies`、`lateFrames`、`conversionUs`、`maxConversionUs`、
  `sourceFrameRate`、`queuedVideoFrames`、`outputPixelFormat: bgra8-srgb` 和
  `hdrOutput: false`。计数与耗时随时间线清空。`frames` 是提交数，
  `textureCopies` 是 Flutter 取纹理次数（可重复），**都不是实际屏幕显示帧数**。
  耗时只包括 pixel buffer 分配和转换，不包含核心解码、屏幕呈现或 GPU 完成时间。

### 实际执行结果

| 检查 | 本次结果与边界 |
| --- | --- |
| 固定源 universal SDK 构建与校验 | 通过；FFmpeg n9.0.2，源提交 `946fcce07b6dcd0331c8cc609192aeff5e1924f8`，含 libass/dav1d |
| owned core Release 构建 | 通过；arm64+x86_64，部署下限 12.0；不等于 Intel 实机运行 |
| 直接加载本次核心 | ABI 8；`ffmpeg=n9.0.2;avformat=4129126;avcodec=4129126;avutil=3998054`；这是 SDK/core 构建树加载，不是新 `.app` 的实际加载 |
| 插件编译 | arm64/x86_64 Objective-C++ 对象编译通过；`-Wall -Wextra -Werror`；没有完成应用链接、安装和启动 |
| macOS 原生输出 CTest | 2 通过（几何/调度、Accelerate 内存像素转换），1 失败（真实 IOSurface）；无 skip |
| 原生核心 CTest | 4 通过（帧成本、音频会话、portable color、startup），1 失败（慢外部 ASS）；无 skip |
| Python 打包/证据契约 | `verify_bundle_test.py` 16、`capture_playback_test.py` 3、`player_smoke_test.py` 4 通过；包含模拟数据，不是新 `.app` 的包审计或播放 |
| `flutter analyze --no-pub` | 失败：本机缺少锁文件所需的 `file_selector` 缓存，产生 4 个相关诊断；未修改相册代码或依赖约束 |
| Flutter surface retirement 回归 | 加载阶段失败：监听 `127.0.0.1:0` 被拒绝（errno 1），测试正文未执行 |
| 新 `lib/main.dart` Release `.app` | 未完成：共享 SDK 缓存不可写；改用工作树内 SDK/config 后，Xcode/SwiftPM 的用户缓存和系统服务权限仍失败 |
| 本地启动脚本 `macos/player_smoke.py` | 已按默认完整路径执行，退出码 1；SDK 校验通过，但创建 `~/Library/Containers/com.sakullla.rillight/Data/rillight-validation/20261001-215901` 被拒绝（errno 1）。在构建和应用启动之前退出，没有使用旧包冒充候选 |
| GUI、变化画面、实际 decoder、物理声音、同步、GPU 稳定性 | 未验证；未以核心事件、内存像素或旧 `.app` 代替 |

核心 dylib SHA256：`bea4cf300b04bc9aa26c64fcd5f9778e3e2ba9c4d665e999d1f83522a2fc58f5`。
路径为 `build/macos-core/librillight_core.dylib`。未产生本次可发布 `.app` 哈希。
SDK marker 位于 `build/macos-core-sdk/rillight-core-dependencies.json`。

IOSurface 失败为 `PixelBufferOutput::Render: -6662`。使用原来的
`CVPixelBufferCreate` 参数分别创建 2×2 和 1280×1280 作为对照，也返回 `-6662`，
并出现 `kIOSurfaceMethodSetCoreVideoBridgedKeys failed: 10000003`。这只能说明当前
执行环境无法完成原生纹理验证，不能据此宣布新路径通过，或改用不含 IOSurface 的制品。
慢外部 ASS 仍在 `ass_test.cpp:569` 的 9s pending 等待失败；历史记录已有相同类别
失败，本次没有放宽超时、删除断言或修复该独立问题。

日志与编译对象保留在 ignored `build/macos-adaptation-20261001/`：
`sdk-build.log`、`core-tests.log`、`frame-tests.log`、`native-core-probe.log`、
`iosurface-probe.log`、`flutter-release-local-sdk.log`、
`flutter-release-local-sdk-pods.log`、`flutter-analyze.log`、
`surface-retirement-tests.log`、`local-launch-smoke.log`、
`local-launch-script-tests.log` 和 `plugin-{arm64,x86_64}.o`。这些不会随 Git 传输。

### 后续原生验收

在具备原生系统服务、Xcode 缓存与屏幕捕获权限的同一主机，先完成依赖恢复与构建：

```sh
export RILLIGHT_MACOS_CORE_PREFIX="$PWD/build/macos-core-sdk"
export RILLIGHT_MACOS_CORE_DYLIB="$PWD/build/macos-core/librillight_core.dylib"
export RILLIGHT_MACOS_CORE_SHA256="$(shasum -a 256 "$RILLIGHT_MACOS_CORE_DYLIB" | awk '{print $1}')"
flutter pub get
cmake -S packages/rillight_player/native/core_tests/macos -B build/macos-frame-tests \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0
cmake --build build/macos-frame-tests
ctest --test-dir build/macos-frame-tests --output-on-failure
flutter build macos --release --target lib/main.dart
python3 macos/verify_bundle.py build/macos/Build/Products/Release/rillight.app
python3 macos/player_smoke.py
```

随后补逐编码变化帧、暂停 seek 预览、倍速/切轨/字幕、resize/全屏/跨屏、
重复开关和睡眠唤醒，以及实际 decoder、物理音频与音画同步。
真正 HDR/EDR 原生层、高精度核心输出契约、真实 DV Profile 5/8 样本、
SDR/HDR/DV 的 60fps 与弹幕呈现、Atmos 对象或 HDMI 压缩直通均未实现或未验证；
本次仍是 SDR 纹理输出，不宣称整份适配清单已闭合或取得性能收益。

## 2026-10-01 本机补测（工作树，HEAD 0150f79）

主机是 MacBook Air / Apple M3 / 10 核 GPU。`system_profiler SPDisplaysDataType` 只列出内置 Liquid Retina，2560×1664，没有刷新率或 HDR 开关。`NSScreen` 当前 EDR headroom 为 1.0，潜在倍数为 2.0。Impeller 启动日志为 MetalSDF。核心 `build/macos-core/librillight_core.dylib` SHA256 为 `3d4fb0971cba2b89afa278fa5ee7595d5becfae8eaf576c1587cfdf4356ebc11`，通用二进制。`actual_hardware=2` 表示 VideoToolbox。下列合成媒体没有杜比视界 RPU。

### 基本播放

`macos/player_smoke.py` 在最新插件上通过。证据目录 `build/player-validation/macos-runs/20261001-235415`：控制通过，窗口捕获通过。H.264 1080p60、HEVC 4K、AV1、VP9 各有连续变化的彩色窗口帧，首帧彩色约 1.3–1.5 秒。物理声音和硬件验收保持 `not_run`。

同一 1080p60 H.264/AAC 文件上，暂停 250ms 期间位置只增加 1µs；恢复后跳到 1.5s 并继续出帧；2× 后 `playback_speed=2`。视频队列峰值 3 帧。无声 H.264 只有视频帧。AAC 纯音频为 48 kHz 立体声 S16，没有视频帧。

没有做全屏、resize、跨屏、反复开关窗口、后台恢复或睡眠唤醒。

### HDR

PQ HEVC（`smpte2084`，10 位）在打开 macOS EDR 时 30 帧都是 RGBA16F，抽样峰值 81.8；关闭时 30 帧都是 8 位 RGBA，峰值 1.0。HLG（`arib-std-b67`）同样：打开时 RGBA16F 峰值 8.18，关闭时 8 位峰值 1.0。两者 `actual_hardware=2`。

独立窗口把 PQ 帧送进 `RGBA16Float` / `kCGColorSpaceExtendedLinearDisplayP3` / `wantsExtendedDynamicRangeContent` 的 CAMetalLayer。画布读回 1280×720，峰值仍是 81.812，超过 1.0 的颜色通道有 1294784 个。送画前后屏幕当前 headroom 都是 1.0。窗口里能看到彩条，但这不是面板高光已被抬升的证据，截图也不能代替。没有 Profile 5/8 杜比视界样本，不宣布支持；不支持组合的核心错误码仍是 -20001，这次没有用真实样本触发。

### 60fps 与弹幕

1080p60 取帧间隔中位数 15048µs，低于 16.67ms 的一帧预算。这是核心交出帧的间隔，不是屏幕扫描间隔。1920×1080 IOSurface 分配加 RGBA→BGRA 的中位数是 601µs，最大 3359µs，没有因此加纹理池。窗口捕获的采样间隔约 1 秒，不能证明 16.67ms 的显示节奏。没有在 1.25×、2×、全屏、HDR10 或杜比视界上复测 60fps。

`flutter test test/player/danmaku/danmaku_renderer_cases.dart` 11 项通过，包括控制栏渐变不压暗白色弹幕。这是 widget 像素断言，不是 60fps 片源上的实机弹幕。

### 杜比音频

E-AC-3 和 TrueHD 都解出 48 kHz 立体声 S16 PCM。默认输出设备是「MacBook Air扬声器」，2 声道。CoreAudio 接受了 11520 字节 PCM，没有报错；开始时设备时间戳尚无效。没有做扬声器或耳机听感，也没有 Atmos 对象渲染或 HDMI 压缩直通。

### 2026-10-02 显示路径耗时

Flutter Impeller 只收 8 位 BGRA 或双平面 8 位 YUV，YUV 矩阵写死 BT.601，所以 VideoToolbox 的 NV12 不能直接交给纹理。播放窗口是整窗物理像素。旧的逐像素拟合把 1920×1080 彩条放进 2940×1846 窗口，中位数 61996µs，最大 63108µs。方像素画面现在保持窗口宽高比，但不再在 CPU 上放大；同一次测量得到的缓冲是 1920×1206，中位数 359µs，最大 1070µs。1920×1080 原尺寸 IOSurface 池的首次分配 3451µs，之后中位数 171µs（此前每帧新建时中位数 601µs、最大 3359µs）。帧测试 3 项通过。这不是屏幕扫描间隔。

`macos/player_smoke.py` 证据 `build/player-validation/macos-runs/20261002-002008` 失败。1080p60 合成片只有 12 秒，脚本却在这段里改窗口大小、进出全屏并在约 25 秒后设置 2×。文件结束后核心拒绝变速，错误是 `Core rejected rate (-1)`。窗口在 1470×923 和 960×540 之间跳过，随后进入全屏。这次没有形成通过的窗口证据。全屏、resize、1.25× 和 2× 的 60fps 显示仍未验收。

去掉 1080p 中途改窗口之后，`macos/player_smoke.py` 通过。证据目录 `build/player-validation/macos-runs/20261002-010128`：控制通过，窗口捕获通过。H.264 1080p60、HEVC 4K、AV1、VP9 各有连续变化的彩色窗口帧，首帧彩色约 1.2–1.4 秒，采样窗口 2940×1846。物理声音和硬件验收仍是 `not_run`。采样间隔约 1 秒，不能证明 16.67ms 的屏幕刷新。生产包已用 `lib/main.dart` 重新构建。

### 2026-10-02 倍速与解码耗时

同一条 12 秒 1080p60 H.264，VideoToolbox。核心按播放时钟交帧，队列保持 3 帧，没有把屏幕扫描间隔测出来。

| 倍速 | 实测速度 | 交帧间隔中位数 | 最大间隔 | 名义间隔 |
| --- | --- | --- | --- | --- |
| 1× | 1.00 | 14085µs | 20589µs | 16667µs |
| 1.25× | 1.25 | 13589µs | 18142µs | 13333µs |
| 2× | 2.00 | 7241µs | 13657µs | 8333µs |

1× 中间隔短于 16.67ms，是因为取帧允许提前约 10ms。1.25× 和 2× 都把速度应用到了时钟，队列没有被抽空。最大间隔里包含变速后的恢复。没有全屏或改窗口。

直接对 VideoToolbox 帧计时，不含播放时钟。1080p H.264：读回中位数 79µs、最大 239µs，swscale 到 RGBA 中位数 381µs、最大 649µs。4K HEVC：读回 326µs / 1170µs，swscale 1469µs / 1807µs。8 位解码和颜色转换都远小于一帧预算。

另做了一条 2 秒、1920×1080、60fps、HEVC Main 10，复用标签 `smpte2084` / BT.2020。这是 testsrc2，不是标定过的 HDR 母版。打开 EDR 时 90 帧都是 RGBA16F，峰值 81.812，`transfer=16`，`hw=2`，队列 3，交帧中位数 15099µs。关闭 EDR 时 90 帧都是 8 位 RGBA，峰值 1.0，中位数 18310µs，队列仍是 3。面板 headroom 没有在这次测量。把同一条 HEVC 标成 `dvh1` 且没有 RPU 时，核心进入失败状态，`ffmpeg_error=-20001`，没有吐出视频帧。

### 2026-10-02 窗口、倍速、弹幕

证据 `build/player-validation/macos-runs/20261002-015728`：控制和窗口捕获通过。60 秒 1080p60 上一次完成这些步骤，没有来回改窗口：

- 1× 时插件提交间隔 8 次为 15489–16720µs，中位约 16400µs。2.5 秒内 152 帧，`lateFrames=0`。最近一帧转换 3360µs。
- 白色滚动和固定弹幕叠在彩条上，窗口图能读到 “Rillight 60fps danmaku”。
- 1.25× 后继续播放。稳定段约 5 秒出 377 帧，`lateFrames=0`，一次提交间隔 14801µs，转换最大 5556µs。
- 窗口改到 1100×620 点，捕获为 2200×1240，彩条仍在动。
- `windowManager.isFullScreen()` 返回 true，没有异常。捕获到的窗口仍是 2200×1240，没有变成整块屏幕。不能把这次叫做已验证的全屏画面尺寸。
- 2× 后 2 秒内 245 帧，`playing=true`，`lateFrames=0`，转换最大 3733µs。

`windowManager.hide()` 会卡住播放 isolate，后台恢复没有做成。本机只有一块内置屏，没有做跨屏。没有让机器睡眠。物理扬声器、Atmos 对象渲染和 HDMI 压缩直通没有做。生产包已用 `lib/main.dart` 重新构建。

### 2026-10-02 v0.1.36 候选：4K HDR60、启播与交互修复

环境：Apple M3、macOS 27、Flutter 3.47.4；性能对比基于 `d094017cd129fb0b08de3be2c2fce760f60284fd` 的工作区；发布前合并了远端 v0.1.35 的 Android JNI 与首页续播修复。下面的数据属于本轮候选改动，不能归为基线提交原有能力。原生库为本机构建的 universal SDK/core，正式应用使用 `lib/main.dart` 入口，临时诊断入口不进入交付。

4K HDR 性能改动包括 Metal 颜色转换、FP16 位模式复制和 EDR 纹理复用。本轮临时合成片、测量程序和原始日志按用户要求清理；本节保留观察摘要，不包含用户媒体地址或凭据。`hdr60-pq-eac3.mp4` 是 HEVC Main 10、3840×2160、60fps、PQ、6 声道 E-AC-3 合成片。它不是 HDR 母版、杜比视界参考素材或物理声音验收材料。

| 本机测量 | 修改前 | 修改后 | 证据边界 |
| --- | --- | --- | --- |
| HDR 帧拟合到 2940×1846 | 约 48.5ms | 约 4ms | CPU 内存操作，不是显示间隔 |
| 4K 线性半浮点转换 | 约 46.7ms | 约 13.45ms | Metal 路径含 staging/copy，不是全链路零拷贝 |
| 同一合成片核心输出 | 约 29–32fps | 约 60.1fps，360 帧 | VideoToolbox 核心取帧，不等于 Flutter 窗口验收 |
| 独立 Cocoa EDR 窗口 | 未测 | 提交 360、呈现 359，约 60fps | 2294×1290；不是 Emby 网络链路和 Flutter 控制层验收 |

临时测量文件已清理。新增 Metal/CPU 颜色等价测试涵盖 PQ/HLG、DOVI polynomial/MMR 参数及多种像素格式；参数等价不代表真实 Dolby Vision 样片验收。物理扬声器、Atmos 对象、HDMI 直通、面板 HDR 高光仍未验证。用户曾反馈一次“都正常，播放明显流畅”，其后又复现网络启播/跳转问题，不能据此前反馈宣布所有播放问题解决。

真实网络复现使用临时诊断入口，经 localhost 上报白名单计数；没有记录账号、完整媒体 URL、签名或令牌。记录表明 `avformat_find_stream_info` 曾在 45 秒内下载约 200MB 而没有首帧。嵌套 AVIO 回调使用 `avio_read`，在 MP4 为跨轨道 seek-back 扩展缓冲后，每次跳转强制读满约 16MiB；改为 `avio_read_partial`，允许可用数据立即返回。参考 FFmpeg 官方 API：<https://ffmpeg.org/doxygen/trunk/avio_8h.html>。对有完整视频样本表的 MP4 使用头部元数据启动，未知音轨不阻挡已支持轨道；其他容器和不完整元数据保留完整探测。未选中的轨道不再读取 payload，切换时重新启用。

缓存链路另发现：已有缓存前缀被远端缺口验证阻塞、切换读位置丢失尚未凑满的有效块、并发旧请求取消新请求，以及正常取消误触发整部视频的预读回退。修复围绕有限分块、共享预读、保留已验证字节和取消代际展开。保留强 ETag/范围/总长校验，未取消缓存预算。上游请求依然封闭在本地代理，原生层只接触 loopback URL。真实片源的最终启动、跳转及重新打开结果应以本节后续验证记录为准。

应用产品名改为 `Rillight`；播放器前置采用 macOS cooperative activation；MOV_TEXT 加入字幕解码路径。页面与播放器 macOS 触控板手势、手机服务器管理（搜索、改名、线路编辑、明确删除及撤销）、首页整张推荐卡片进入详情已有代码和 widget 回归。手机 widget 渲染不等于 Android 真机验收；未在本轮声称 Android 的播放退出、手势导航及锁屏恢复已通过。


实际 Emby 播放窗口后续采样：60fps 版本在连续 99.000792 秒内，Metal drawable 呈现计数增加 5938，约 59.979fps，实际解码器为 VideoToolbox。另一个自动选择的版本实际为 25fps，两者没有混算。25fps 版本完成前跳到 5 分钟、回退到 1 分钟、重新开始及关闭后再开；实际 Cocoa 窗口两张相隔 2 秒的截图中央区域约 94.9% 像素发生变化。这不验证物理声音或面板 HDR 高光。

请求密集时的本地 503 来自并发槽尚未被关闭回调释放；有限排队替代立即拒绝，正常播放采样有 44 次排队、0 次拒绝。后续用户再次报告正常播放的缓存缺口；对应补读连续 403，先前的“播放正常”反馈不能覆盖这个长时场景。预读耗尽瞬态连接重试后，也通过同一地址续期入口恢复，带 30 秒间隔限制。候选新增同一 MediaSource 的 PlaybackInfo 地址续期，原生封闭路由保持不变，新字节仍校验强 ETag/范围/总长。一次受控本地 403 注入后，应用自动请求真实 PlaybackInfo 并恢复下载，核心会话、时间线和位置持续推进，没有重新打开解码器；合成 HTTP 测试另验证旧缓存复用与新 URL 补读。缓存回收优先释放回退保留范围之外的已播放块，保留初始化数据及活动读取保护。

UI 回归覆盖：未配置弹幕时隐藏入口；只有一个可用音轨、画质或片源时隐藏对应切换；字幕入口始终保留“关闭字幕”项；成功换源后的兼容音轨回退不再误报加载失败。缓存条对短暂校验繁忙保留最近确认的区间，同时仍会撤回真实失效或超时不可确认的数据。macOS 页面/播放器手势和手机服务器管理的 widget 测试通过；本轮没有 Android 真机验收。

发布前校验：Flutter 格式化、静态分析通过；完整 Flutter 测试 978 项通过。原生核心 CTest 7 项、macOS 帧输出 CTest 3 项、macOS 包装/签名/烟测脚本单元测试 30 项通过。正式 macOS 0.1.36（build 37）构建通过，包审计检查 14 个 Mach-O 和 9 个哈希验证的 universal core dylib。临时诊断进程、HTTP 接收器、复现脚本、测试媒体和原始日志按用户要求清理；项目正式回归测试保留。Windows/Linux/Android 的候选原生构建由发布 CI 执行，本机不将其记为已验收。

### 2026-10-02 v0.1.37 后续修复

下一集的预下载拼接通道此前未统计续流下载、未登记该集缓存表示，导致正常下载时速度为 0、缓存条缺失。现在将当前响应已验证的续流写入缓存并统计速度；预下载前缀没有当前验证器，不能冒充已确认的新表示。HTTP 与 backend 两个回归覆盖切到第二个会话后跳转、速度更新及当前缓存区间。相关模块 119 项通过。

v0.1.36 发布失败的 macOS 与 Ubuntu 步骤均在第一次 seek 返回 `-1094995529`，事件记录显示开流成功、同次 seek 后 core FAILED。HTTP `offset` 已定位到请求字节，但新建 AVIO 的逻辑位置仍是 0，小偏移的 `avio_seek` 因而再次读取并跳过同样的偏移。短 WAV 的原生回归在修复前得到错误的首采样 11，修复后为正确的 0；恢复点为文件偏移 44 字节。现在同步 AVIO 绝对位置，原生 CTest 8 项通过。本机完整 macOS 控件烟测受容器目录权限限制未执行完成，实际 hosted-runner macOS 与 Ubuntu 验收以新的 CI 结果为准。没有修改或降低发布验收条件。
