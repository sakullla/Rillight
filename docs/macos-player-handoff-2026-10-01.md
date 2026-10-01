# macOS 播放器适配交接（2026-10-01）

## 候选与当前结论

基准提交：`ea12d3a`。候选为包含本文档的提交，可用 `git rev-parse HEAD` 记录其完整版本号。本轮在 Windows / Flutter 3.47.4 上开发，原生依赖固定 FFmpeg n9.0.2、核心 ABI 8。本文中的验证记录是开发工作树结果；目标机应绑定自己的提交、构建输入和应用 SHA256。

**macOS 本轮尚未编译、安装或验收。当前 macOS 输出是 8 位 BGRA Flutter 纹理，没有实现真正的 EDR/HDR 高亮输出。Android 已补做真机重试，基本原生播放通过，但杜比倍速及跳转后的变化画面检查失败，详见下节。** 保留历史记录于 [TESTING_HANDOFF.md](../packages/rillight_player/macos/TESTING_HANDOFF.md)，不要把历史 n9.0.1 制品当成本轮候选。

## Android 真机重试与传输修复（2026-10-01）

本节验证对象是 `5e2653f109aada4ae00017ee3ae36f1c2b253b7b` 加本次传输修复的工作树，随后提交包含修复与本文档。以下上一轮的 948 个测试及无设备记录保留为历史，不代表重试结果。设备是 PKM110 / Android 16（API 36），仅安装可丢弃的 `com.rillight.rillight.validation`，没有清理或覆盖正式应用。使用 arm64 debug、Flutter 3.47.4、FFmpeg 9.0.2、Impeller Vulkan，以及合成凭据/本地媒体；没有伪造登录 UA。

### 确认的故障与修复

原生检查在切换音轨及嵌入字幕后，暂停报 `Playback is opening or closed`。独立重跑同样失败；诊断记录核心 I/O 错误 `-5`、`transportWorkerExited: true`、`HttpException`，对应代理正文的 `Media body cannot safely resume`。解码器探测或 seek 关闭下游读取时，直接 `HttpResponse.addStream(body())` 可能漏接 async* 正文生成器的后续错误，导致传输 isolate 退出。

`lib/player/playback_http_proxy.dart` 现在让前台正文与缓存正文共用 `_sendBody`，由 `StreamIterator` 持有生产者，并在 finally 中等待取消结束。保留真实截断错误及 representation validator 检查，不通过扩大超时或不安全续传掩盖故障。新增 transport 用例验证无 validator 的截断读失败后，worker 仍能处理暂停、seek 和下一次正常请求；该小用例在旧代码上也通过，不能声称其稳定复现 Android 取消时序。实际前后对照来自手机原生失败及修复后独立运行通过。

验证脚本还修正了两处交互：新版首页通过 `phone-hero-open` 进入详情；控制栏保持 mounted 时，先确认实际显示，再点击锁定按钮，避免点击已隐藏控件。

### 已执行结果与剩余问题

| 检查 | 结果 | 边界 |
| --- | --- | --- |
| 全量 Dart 测试 | 949 个通过，0 失败，159s | 包含新增 transport 用例；不是设备播放验收 |
| HTTP 代理 / transport 专项 | 67 个通过 | 单元回归 |
| Android 验证工具测试 | 27 个通过 | 工具回归 |
| `flutter analyze` / 两个改动 Dart 文件格式检查 | 通过 | 无分析问题，格式无变化 |
| 修复后真机原生检查 | 通过 | 音轨/字幕、暂停/seek、Surface 重建、HLS/跨域、401、失败隔离、重试及 dispose；捕获实际变化彩色画面 |
| 正式手机界面流程 | 通过 | 合成登录、详情播放、屏内锁定/解锁、暂停/恢复、横屏、后台/前台、返回详情/首页、搜索断网重试，以及 Playing/Stopped 报告；不含物理音频验收 |
| APK 与 SDK | 通过 | arm64 ELF/依赖闭包核验及设备安装 SHA256 匹配；不是三 ABI Release 验收 |
| 4K HEVC Main 10 / PQ / 60fps 样本 | 变化画面检查通过 | 1×、1.5×、暂停 seek 后恢复的两帧截图均变化；实际 decoder 为 software，未测显示帧率 |
| 4K 杜比样本（dvh1 / 25fps） | **未通过** | 初始 1×变化画面通过；1.5×与 seek 恢复时截图差值均为 0，虽然 position 前进且无 core error，不能据此称播放通过 |
| 真正 Android HDR、实际 60fps、硬解性能、物理声音 | 未验证 / HDR 输出尚未接通 | 当前 Android RGBA8888 路径进行 SDR 映射；没有建立 HDR 亮度、帧节奏或物理音频证据 |

真机原生画面检查平均 RGB 差值约 3.47，彩色像素比例约 99.98%；HTTP 检查记录授权请求 23、跨域请求 5、凭据泄漏 0、Range 请求 14。这里的通过只针对记录的合成样本与检查步骤。杜比倍速/跳转的静止画面仍需检查 decoder、转换耗时、输出队列和 Surface 呈现，不得用控制命令成功代替画面证据。

用户在本次提交前明确反馈：HDR 60fps 仍严重卡顿，杜比画面偏绿。两项均按未达标处理；上述截图变化不证明性能或颜色正确。后续需继续适配原生 Android 解码、色彩处理及显示管线。

本机 ignored 证据目录（不会随 Git 传到 macOS）：

- 原失败：`build/android-validation/runs/5e2653f-native-phone-current/`、`5e2653f-native-phone-after-install-guide/`、`5e2653f-native-phone-diagnostic/`、`5e2653f-native-phone-transport-diagnostic/`。
- 修复后原生通过：`build/android-validation/runs/5e2653f-transport-repair-native/result.json`，APK SHA256 `c3230c20cde6cbc03085871e3296c1c019e72bbb691da4a3af01c557130d76bc`。
- HDR / 杜比：`build/android-validation/runs/5e2653f-transport-repair-hdr-20261001-162551/result.json`；保留失败截图和 native 日志。
- 旧脚本失败：`5e2653f-transport-repair-app/`（误点标题）、`5e2653f-transport-repair-app-current-actions/`（误点隐藏的锁定按钮），不能删除失败记录或改写为通过。
- 更新脚本后手机界面通过：`build/android-validation/runs/5e2653f-transport-repair-app-visible-controls/result.json`，APK SHA256 `f1cc700e5947dc2299b5ef862a02544d2c347bdce306b210a97fe073eb2cbd31`。真机无法取得模拟器 gRPC 音频，保留 `audio.json` 失败；UI/控制通过与整体未验收分开记录。
- 测试日志：`build/android-transport-repair-full-tests.log`、`android-transport-repair-tests.log`、`android-transport-repair-tool-tests.log`、`android-transport-repair-analyze.log`。

## 已交付改动与入口

| 范围 | 实现入口 | macOS 需检查 |
| --- | --- | --- |
| 弹幕颜色 | `lib/player/playback_control_scrims.dart`、`player_page.dart` | 控制栏渐变位于弹幕下面；显隐时白色填充应保持稳定，检查 HDR 合成后的真实画面 |
| 弹幕拥挤 | `lib/player/danmaku/danmaku_layout.dart` | 自动密度按文字占用面积限制新入场，固定/滚动模式共享物理行避让；手动密度仍按用户设置 |
| 控制栏自动隐藏 | `player_controller.dart`、`playback_settings_menu.dart` | 换源卸载设置菜单会释放其自己的 pin；其他面板占用不被清除；重复 playing 通知不唤醒隐藏控件 |
| 播放设置 | `playback_settings_menu.dart` | 桌面左侧分类、右侧选项；窄屏横向分类；操作等待实际结果，测试切轨/换源失败恢复 |
| 片头片尾 / 下一集 | `playback_skip_settings.dart`、`next_episode_card.dart` | 关闭提示后不自动跳过；提示条尺寸、键鼠操作和下一集启动；TV 使用遥控器可聚焦选项 |
| 缓存条 | `buffered_ranges_track.dart` | 时间索引存在但区间为空时使用真实缓存字节映射；不把空缓存显示为已缓冲 |
| 进度预览 | `bif_preview.dart`、`seek_preview.dart`、`lib/emby/emby_client.dart` | hover/拖动时间、BIF/章节图；图片不可用时只显示时间 |
| 首页 | `lib/home/home_hero.dart`、`hero_artwork.dart`、`hero_playback_actions.dart` | 宣传图优先，剧集续播使用父剧正式图片，避开本集生成帧；海报包含展示；继续播放与详情同行 |
| 图片尺寸 | `lib/media_image/media_image.dart` | 缩放和缓存行为、相册入口仍要求至少两张图片；既有放大下载操作需实机复测 |
| 1×音频 | `native/core/rillight_core.cpp` | 1×绕过 atempo，保留格式转换和声道处理；切换 1×/1.25×/2×后声音、同步及 seek |
| Android 解码恢复 | 同上 | MediaCodec 在 seek/变速/切轨的 flush 点重建；macOS VideoToolbox 沿用自己的路径，需独立测试 |
| Windows 呈现 | `windows/video_schedule.h`、`video_surface.cpp`、`hdr_host.cpp` | 暂停时目标帧提交、HDR backing 初始化顺序是 Windows 专用修改，macOS 需要对应平台实现 |
| macOS 接口 | `macos/rillight_player/Sources/rillight_player/include/rillight_player/rillight_core.h` | 已同步 owned core 头文件；保持 ABI、struct_size 与加载库一致 |

上述包内路径以 `packages/rillight_player/` 为起点。首页图选择检查尺寸、比例和图片来源，没有实现模糊程度识别。弹幕没有人脸检测；本轮确认了控制层黑色渐变压暗弹幕的问题，并有像素回归。仍需在实际显示器上长时间观察，不能据此宣布所有闪烁已经消失。用户要求暂缓的详情续播白屏问题仍需观察。

## 本轮验证与边界

| 检查 | 结果 | 证据范围 |
| --- | --- | --- |
| 原全量 15 个失败用例 | 已修复并通过对应模块回归 | 保留字幕选择、倍速/服务设置合并保存、换源失败恢复、返回和焦点等业务断言，无 skip |
| 最终 `flutter test --reporter expanded` | 948 个全部通过，0 失败，155s | 本机全量单元/widget，不等于原生设备验收 |
| `flutter analyze` | 无问题 | 本机静态分析 |
| `python macos/verify_bundle_test.py` | 16 个通过 | Windows 上运行的可移植打包/头文件契约测试，含模拟 Mach-O 检查；没有构建真实 macOS 应用 |
| Windows 正式 `lib/main.dart` Release | 构建通过，51.1s；依赖/ABI 核验通过 | 加载 ABI 8、FFmpeg 9.0.2；不证明物理声音、60fps、杜比/HDR 全部通过 |
| Android 手机与 TV 页面 | widget 回归通过 | 假后端交互检查；最新 APK 未安装到真机，当前 `adb devices -l` 无设备 |
| macOS / Linux 本轮原生播放 | 未验证 | 必须在对应主机补做 |

原始日志位于当前 Windows 工作区的 ignored `build/`：`failure-repair-full-tests.log`、`failure-repair-analyze.log`、`failure-repair-macos-contract.log`、`failure-repair-windows-release.log`、`failure-repair-windows-dependencies.log`。不会随 Git 提交传到 macOS。旧日志、截图和短时间录制只作相应版本的补充证据，不能替代最终候选的实机验证。

## macOS 构建步骤

要求 macOS 12+、Flutter 3.47.4、Xcode/CMake/Python，以及固定来源的 x86_64+arm64 SDK。构建 inputs 和依赖闭包规范见 [播放器 README](../packages/rillight_player/README.md)。示例从仓库根运行：

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

## 验收记录

每个样本记录媒体编码/profile/位深/帧率/音轨（去除媒体 URL 凭据）、机器/屏幕/刷新率/HDR 能力、候选与制品哈希、实际 decoder、操作步骤和结果。按 [证据规范](../tool/player_release_evidence.md) 分开记录构建、包启动、变化画面、物理声音、同步及 GPU 稳定性。性能改进需要相同媒体/机器/设置的基准与候选测量。

完成目标机适配后，将新结果追加到包内 `TESTING_HANDOFF.md`；失败样本保留。Android 恢复连接后，用 `.validation` 包和合成凭据验证最新 native core，尤其 seek/变速/切轨后画面是否持续变化，以及退出播放后手势导航、锁屏/唤醒。不要覆盖用户正式应用的设置或把旧手机结果升级为当前候选通过。
