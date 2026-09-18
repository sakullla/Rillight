# 灯川 Rillight

独立桌面影视客户端。在 Windows、macOS 与 Linux 上连接已有 Emby 服务器，浏览并播放电影与剧集。默认界面为简体中文。

本仓库只包含桌面目标（`windows` / `macos` / `linux`），不含 Android 或 iOS。播放由仓内 `packages/rillight_player` 直接接入 libmpv，三平台均使用独立播放进程。每次媒体打开拥有独立内核、视频表面和会话身份；关闭等待原生音画与纹理释放。

发行包捆绑 libmpv 和媒体依赖，Windows/Linux 的版本、来源与校验值见 [`dependencies.json`](packages/rillight_player/native/dependencies.json)。当前稳定版基线为 mpv 0.41.0；Windows 固定构建为 `0.41.0-1023-g69e63f425`，它是 git 构建。macOS 在构建时从 IINA 的 live dylib 列表下载 universal 库，不在仓库内锁定远程文件哈希；应用最低版本为 12（Flutter 3.47.4 要求）。Linux deb 自带新版 `libmpv.so.2`，不需要手工创建 `.so.1` 软链接或设置 `LD_LIBRARY_PATH`。使用桌面菜单或 `/usr/bin/rillight` 启动；依赖缺失时启动包装会提供诊断。

配套 FFmpeg 基线升级为 9.0.1，Linux 按固定提交整套重建；Windows 保留兼容的固定开发构建 `N-126390-g9fc8c785e`。版本检查读取实际加载库的属性，不根据文件名推断版本。macOS 媒体库的实际加载与签名仍需对应系统验证。

## 开发

使用已启用桌面支持的 Flutter 3.47.4；CI 固定此版本，以匹配原生纹理注销顺序验证。

```sh
flutter pub get
flutter run -d windows
flutter test
flutter test --tags integration
python tool/verify_player_dependencies.py
```

原生依赖构建与许可证说明见 [播放器包说明](packages/rillight_player/README.md)。macOS Runner 在签名前捆绑固定的媒体库；PR/main CI 包含 Linux 安装包回归和 macOS 构建/捆绑检查，配置分别见 `.github/workflows/linux-package.yml` 和 `.github/workflows/macos-package.yml`。

截至 2026-09-18，Windows 正式主入口/独立播放进程验证已通过，PGS、ASS、SRT、VTT、SSA 的内核合成 PNG 已逐一检查，普通发行入口已恢复构建。Docker Ubuntu 22.04 已完成正式构建、deb 打包和全部 ELF 检查，实加载 mpv 0.41.0（含固定的缩放表填充修复）、FFmpeg 9.0.1、client API 2.5；Ubuntu 24.04 已通过桌面启动、关闭和缺库可见诊断。Linux 主入口与独立播放窗口的 H.264、HEVC、AV1、VP9 连续彩色画面、字幕、seek、切换及关闭重开已通过，音频流已接入虚拟 sink。验证使用 Xvfb/软件 Mesa，1080p/4K 掉帧明显，不代表硬件实时吞吐或物理音频输出；macOS 尚无实机结果，新增 CI 尚未执行。硬件 GPU、端到端音画同步及历史闪屏仍需对应环境验证。

Windows 实际播放验证：`powershell -NoProfile -ExecutionPolicy Bypass -File tool/player_smoke.ps1`。脚本需要 FFmpeg（PATH 或 `build/player-validation/tools/`），生成合成媒体与本地 Emby 服务，以 release 模式调用正式主入口和独立播放入口，记录起播、轨道、seek、窗口调整、错误和关闭。凭据、设置、缓存隔离在本次 `build/player-validation/runs/` 目录，脚本结束后恢复普通发行入口。`RILLIGHT_SMOKE_HOLD_SECONDS=5` 可延长每个画面阶段供观察；自动诊断和截图不能证明历史闪屏已彻底消失，也不能替代音频设备听测。

HTTP 媒体、HLS 分段/密钥和字幕经会话本地代理，每次重定向按来源附加 Emby 凭据；第三方请求保留自定义 User-Agent，但不携带 Emby 令牌。播放设置继续使用 MiB，并通过文件锁、合并与原子替换保护主窗/播放进程的并发保存。

On a local Windows developer loop, run `flutter test` for the full suite and `flutter test --tags integration` for the full-page subset. Integration-style tests stay in `test/` and are also included in the full suite; CI checks pass/fail only.

既有测试保留在对应功能目录的 `*_cases.dart` 中，由 `test/suites/` 的少量入口加载；例如 `flutter test test/player/playback_resolver_cases.dart` 可单独运行。新增普通 `*_test.dart` 仍会自动发现；新增或重命名 case 模块后运行 `python tool/test_execution/generate_suites.py`，默认测试会检查是否漏收。完整页面使用逐例 `integration` 标签，纯逻辑和局部 widget 保留在全量测试中；[原用例归属表](tool/test_execution/classification.md)记录标签调整。
