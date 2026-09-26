# 灯川 Rillight

灯川是连接已有 Emby 服务器的 Flutter 影视客户端，支持 Windows、macOS、Linux、Android 手机和 Android TV，界面默认使用简体中文。Android 最低为 API 24；不包含 iOS。

五端共用仓内 [`packages/rillight_player`](packages/rillight_player/README.md) 的自主 FFmpeg 播放核心。应用层管理会话下载、预读、断线恢复、缓存、手动画质和播放状态；底层可调用各系统硬件解码与输出接口。带宽不足时保持所选画质并提示用户，不自动降画质。缓存进度条只显示能由媒体时间索引和完整、可读缓存块证实的区间；不确定的格式或缺失数据保持未知。

手机和 TV 共用数据控制器，但有各自的交互树。手机使用触控和底部导航，TV 使用方向键、确认、返回与媒体键。进入后台会暂停并释放播放资源，返回时保持暂停。设置和播放内容仍依赖你的 Emby 服务器；服务器无法提供请求的转码时会给出错误。

## 开发与验证

使用 Flutter 3.47.4（Dart 3.11.5+）及对应平台工具链。原生构建需要仓库固定来源的 FFmpeg/libass SDK；不同平台的构建入口、环境变量、来源哈希与许可证材料见[播放器包说明](packages/rillight_player/README.md)。缺少 SDK 时构建应明确失败，不会改用 libmpv 或 Media3。

```sh
flutter pub get
flutter analyze
flutter test
flutter test --tags integration
flutter test packages/rillight_player/test
```

Android APK 在设置 `RILLIGHT_CORE_SDK_ROOT` 后使用 `flutter build apk --debug` 构建；SDK 必须含 arm64-v8a、armeabi-v7a 和 x86_64。Android Studio 手机与 TV 模拟器用隔离的 `.validation` 应用和合成凭据验证，操作与证据边界见 [Android 验证说明](integration_test/android/README.md)。桌面使用 `flutter run -d windows`、`linux` 或 `macos`，分别在对应宿主构建。

新增或重命名 `test/*_cases.dart` 后运行 `python tool/test_execution/generate_suites.py`。完整页面用例标记 `integration`；默认 `flutter test` 仍包含这些用例。播放代理、缓存和 UI 用例不能代替实际画面、声音及硬件稳定性测试。

## 候选制品与实测边界

[`tool/player_release_evidence.md`](tool/player_release_evidence.md) 定义制品哈希、原生依赖、安装启动、可见连续画面、物理声音、音画同步和性能对照的独立证据。`tool/player_core_release_checks.py` 与 `tool/player_performance_checks.py` 只审核已有结果；缺证据不会生成通过结论。历史 libmpv/Media3 基线保留在 [验证记录](integration_test/README.md)，不能作为当前核心的成功证据。

Apple M3 目标机已从固定源构建通用 SDK/核心，并完成 Release 包审计、探针、adhoc 签名和沙箱代理；H.264/HEVC/VP9/AV1 窗口画面、物理声音、VideoToolbox 实际 decoder 和 Intel 仍见 [macOS 交接文档](packages/rillight_player/macos/TESTING_HANDOFF.md)。PR CI 在缺少输入时明确标为待验证；正式 macOS 发布构建仍要求固定 SDK/核心输入，不能静默跳过。

网络、页面加载和动画优化需要与冻结基线在同一设备、媒体、网络条件和 profile/release 模式下比较。模拟器、Xvfb、虚拟音频、CI 配置和实体设备观察应分别报告；尚未采集的数据不宣称性能收益。
