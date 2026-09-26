# macOS 自主播放核心目标机交接

状态（2026-09-26，Apple M3 / macOS 27.0）：已在本机从固定源构建 x86_64+arm64 FFmpeg SDK 与 `librillight_core.dylib`，完成 CocoaPod 准备、Release `.app` 依赖审计、核心探针、adhoc 签名、测试 DMG 和沙箱代理。**Finder 启动后的 H.264/HEVC/VP9/AV1 连续变化帧、扬声器/耳机可听声音、VideoToolbox 实际 decoder 路径、Intel 机型，以及限速/断网/性能对照仍为未验证。** 本记录不得当作五平台发行通过；tag 发布仍须固定 SDK/核心输入。此缺口不得用 IINA/libmpv 制品填补。

## 本机环境

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

`native/core_dependencies.json` 固定 FFmpeg n9.0.1、补丁、libass 0.17.5 和 dav1d 1.5.3。macOS 字幕依赖复用同一文件中的 FreeType 2.13.3、FriBidi 1.0.16、HarfBuzz 10.4.0 源钉，静态链入 `libass`，字体提供者为 CoreText。FFmpeg 配置含 `--enable-libdav1d`、`--enable-videotoolbox`、`--enable-network`、`--disable-autodetect`。运行库使用 `@rpath` 与 `@loader_path`，部署下限 macOS 12.0。

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
