# 灯川 Rillight

灯川是连接已有 Emby 服务器的 Flutter 影视客户端，支持 Windows、macOS、Linux、Android 手机和 Android TV，界面默认使用简体中文。Android 最低为 API 24；不包含 iOS。

五端共用仓内 [`packages/rillight_player`](packages/rillight_player/README.md) 的自主 FFmpeg 播放核心。应用层管理会话下载、预读、断线恢复、缓存、手动画质和播放状态；底层可调用各系统硬件解码与输出接口。带宽不足时保持所选画质并提示用户，不自动降画质。缓存进度条只显示能由媒体时间索引和完整、可读缓存块证实的区间；不确定的格式或缺失数据保持未知。

手机和 TV 共用数据控制器，但有各自的交互树。手机使用触控和底部导航，TV 使用方向键、确认、返回与媒体键。普通后台会暂停并释放播放资源，返回时保持暂停。Android 手机 API 26+ 在系统允许时支持手动画中画，播放中回桌面自动进入系统小窗；暂停回桌面不会自动进入。小窗保留同一播放会话及字幕，可用系统按钮播放／暂停；关闭小窗或锁屏会暂停并释放资源。TV、API 24/25 不启用画中画。手机文字字幕支持小／标准／大／特大及原始 ASS 样式，设置与播放面板共用偏好，图片字幕不可调整字号。设置和播放内容仍依赖你的 Emby 服务器；服务器无法提供请求的转码时会给出错误。

## 多服务聚合与私密区域

桌面顶部「聚合」、手机和 TV 的原片库入口使用同一服务/账号/区域访问权威。聚合页的范围管理按钮可设置参与服务、明确选择媒体库、修改服务和线路昵称/顺序、独立账号登录，以及手动检查状态和时间。读取媒体库不会自动勾选新库；未知范围不会扩大为全部媒体。昵称和排序不切换正在播放的线路。

普通区域只提供匿名的私密入口。首次进入需设置并确认 4–12 位 PIN；之后错误尝试有重试时间，取消不解锁。私密页可立即锁定；应用重启保持锁定。迁移普通服务到私密区域会先撤销展示、播放、缓存和记录，再提交成员关系；失败时提示重新检查，不自动恢复播放。PIN 是应用内访问边界，不是媒体或凭据加密功能。

播放器的「手动切换」入口分别列出同服务连接线路、当前条目版本和已确认跨服务作品。切换消费事务预检；时间轴与语言差异需要明确选择，pending 不等于已经观看，记录只根据实际播放事件写入。集映射不确定时禁止直接跨服续播。原型截图和合成后端测试不代表原生五端验收；当前开发验证及尚未闭合的完整测试/设备事实见 [证据边界](tool/player_release_evidence.md)。

## 开发与验证

使用 Flutter 3.47.6（Dart 3.11.5+）及对应平台工具链。原生构建需要仓库固定来源的 FFmpeg/libass SDK；不同平台的构建入口、环境变量、来源哈希与许可证材料见[播放器包说明](packages/rillight_player/README.md)。缺少 SDK 时构建应明确失败，不会改用 libmpv 或 Media3。

```sh
flutter pub get
flutter analyze
flutter test
flutter test --tags integration
flutter test packages/rillight_player/test
```

Android APK 在设置 `RILLIGHT_CORE_SDK_ROOT` 后使用 `flutter build apk --debug` 构建；SDK 必须含 arm64-v8a、armeabi-v7a 和 x86_64。Android Studio 手机与 TV 模拟器用隔离的 `.validation` 应用和合成凭据验证，操作与证据边界见 [Android 验证说明](integration_test/android/README.md)。桌面使用 `flutter run -d windows`、`linux` 或 `macos`，分别在对应宿主构建。

新增或重命名 `test/*_cases.dart` 后运行 `python tool/test_execution/generate_suites.py`。完整页面用例标记 `integration`；默认 `flutter test` 仍包含这些用例。播放代理、缓存和 UI 用例不能代替实际画面、声音及硬件稳定性测试。

Windows 播放窗口预热、实际画面起播计时及合成慢响应对照见 [起播验证说明](tool/player_startup_validation.md)。保持默认 Impeller 渲染器，预热仅提前初始化一个隐藏引擎；点击播放后才请求影片信息和视频。

## 候选制品与实测边界

[`tool/player_release_evidence.md`](tool/player_release_evidence.md) 定义制品哈希、原生依赖、安装启动、可见连续画面、物理声音、音画同步和性能对照的独立证据。`tool/player_core_release_checks.py` 与 `tool/player_performance_checks.py` 只审核已有结果；缺证据不会生成通过结论。历史 libmpv/Media3 基线保留在 [验证记录](integration_test/README.md)，不能作为当前核心的成功证据。

Apple M3 目标机已从固定源构建通用 SDK/核心，并完成 Release 包审计、探针、adhoc 签名和沙箱代理；H.264/HEVC/VP9/AV1 窗口画面、物理声音、VideoToolbox 实际 decoder 和 Intel 仍见 [macOS 交接文档](packages/rillight_player/macos/TESTING_HANDOFF.md)。PR CI 在缺少输入时明确标为待验证；正式 macOS 发布构建仍要求固定 SDK/核心输入，不能静默跳过。

网络、页面加载和动画优化需要与冻结基线在同一设备、媒体、网络条件和 profile/release 模式下比较。模拟器、Xvfb、虚拟音频、CI 配置和实体设备观察应分别报告；尚未采集的数据不宣称性能收益。

本次手机候选验证运行 `python tool/phone_player_validation.py --verify-candidate --evidence-root build/phone-player-validation`；缺少 SDK、设备或配对样本时明确失败并列出未验证项。证据格式见 [播放器证据合同](tool/player_release_evidence.md)，本地多来源与故障夹具见 [Android 验证说明](integration_test/android/README.md)。
