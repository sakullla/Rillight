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
