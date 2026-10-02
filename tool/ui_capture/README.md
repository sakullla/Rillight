# 原型 UI 捕获

`node tool/capture-ui.mjs` 用 Flutter 测试渲染器捕获真实桌面、手机和 TV 页面，不启动原生窗口、不需要 SDK、设备或个人 Emby 服务。沿用 cliora 捕获脚本的填充数据、交互后截图与失败汇总思路。这里的播放器画面是合成插画，不是播放验收证据。

需要项目对应的 Flutter、Node 18+ 和支持中文的字体。自动查找系统字体；也可设置 `RILLIGHT_CAPTURE_FONT=/absolute/path/font.ttf`。字体路径与 SHA256 会记入报告，比较两次截图时使用同一字体及 Flutter 版本。

```sh
node tool/capture-ui.mjs
node tool/capture-ui.mjs --platform desktop --theme dark
node tool/capture-ui.mjs --platform phone --out build/ui-capture-phone
node tool/capture-ui.mjs --feature servers --theme light
node tool/capture-ui.mjs --feature 弹幕 --platform phone --size 360
node tool/capture-ui.mjs --only 'poster-hover*,player-settings-*' --platform desktop
node tool/capture-ui.mjs --only server-delete-confirm --theme light
node tool/capture-ui.mjs --only '*loading*' --list
```

支持 `--platform all|desktop|phone|tv`、`--theme all|dark|light`，默认全部平台和两种主题。`--size` 为配置宽度，可指定 `360,412,1024,1440,1920`。`--feature` 支持下表功能名及对应中文别名。`--only` 支持一个或多个状态 ID、`*`/`?` 通配符，逗号分隔；与功能、平台、主题和尺寸筛选取交集。`--list` 列出当前筛选匹配的状态，不启动 Flutter；空结果会报错。

默认输出到忽略目录 `build/ui-capture/`，每次生成独立运行目录，终端给出 `index.html`。截图索引支持平台、主题和状态过滤。`manifest.json` 保存尺寸、状态、字体、版本、结果与缺失清单；`capture.log` 保留完整日志。失败返回非零退出码，保留已完成截图。手机横屏的 `profileWidth` 仍是竖屏配置宽度，`width`/`height` 为图片实际尺寸。`theme` 是应用主题，`renderedTheme` 说明播放器固定使用深色。

| 功能 | 主要状态 |
| --- | --- |
| `home` / 首页 | 两帧加载过程、内容、货架、鼠标悬浮过程、遥控焦点、手机首页编辑 |
| `library` / 片库 | 片库列表、导航编辑、电影/剧集片库、排序、筛选、继续观看及最新入库列表 |
| `detail` / 详情 | 电影、剧集、季、分集、选季/选集弹窗、分集右键菜单、音轨和字幕选择、剧照查看器与翻页 |
| `search` / 搜索 | 初始、输入、结果、空结果、筛选、TV 输入弹窗 |
| `servers` / 服务器 | 账户、服务器管理、线路新增/编辑、删除确认、重命名、密码及校验、新增服务器/高级设置 |
| `settings` / 设置 | 各折叠分组、主题/倍速/缓存/解码下拉、弹幕配置与高级设置 |
| `login` / 登录 | 已保存服务器、地址校验、高级设置、主题菜单、TV 输入 |
| `player` / 播放器 | 加载、缓冲、暂停、进度预览、手机锁定、横竖屏设置、字幕、片源、倍速、跳过片头/片尾、续播、选集、下一集、结束、错误 |
| `danmaku` / 弹幕 | 样式、开关、高级设置、关键词、匹配搜索/加载/结果/选集/空结果/失败/成功，含手机横屏 |

各端按真实能力捕获：TV 当前没有弹幕入口、手机式首页编辑或桌面式应用设置；手机/TV 的片库列表与桌面的导航菜单分别记录。`scenarios.json` 的 `platforms` 是明确的适用范围，非适用组合不会冒充已捕获。播放器直接按保存进度续播，没有虚构的续播确认弹窗。原生窗口菜单、外部网站/系统文件选择器不在原型范围。

通过真实点击、悬浮或按键打开交互状态；页面路由可直接定位以减少串联依赖。捕获保留指针和焦点。状态缺失、点击未命中、Flutter 异常和布局溢出均导致失败。新增状态同时维护 `scenarios.json` 与对应场景；截图文件名稳定，输出目录隔离。

所有账号、偏好、图片缓存与播放器均为内存夹具。插画由捕获工具绘制，不依赖外网图片。捕获脚本位于 `tool/`，不会加入默认测试收集。PNG 与索引是原型呈现证据，不证明平台原生能力、实际视频、声音或硬件性能。

## 参考与实现取舍

三端筛选、手机布局与缓存显示的设计依据见 [UI/UX 重设计说明](UX_REDESIGN.md)。捕获覆盖从首页实际点进详情的加载／完成帧，并检查主操作的位置；播放器另有下载中与速度归零后的缓存区间截图。

2026-10-02 联网查阅以下官方资料：

- [Playwright Visual comparisons](https://playwright.dev/docs/test-snapshots)：截图随系统、字体及环境改变；记录宿主、Flutter 版本、字体路径及哈希，不把跨环境像素差异当成 UI 回归。
- [Playwright Best practices](https://playwright.dev/docs/best-practices)：隔离状态、控制测试数据、使用稳定定位和可交互性检查。这里使用实际页面的 Key、语义/标签定位与内存数据，缺少入口或点击被遮挡就失败。
- [Flutter pumpAndSettle](https://api.flutter.dev/flutter/flutter_test/WidgetTester/pumpAndSettle.html)：持续加载动画无法 settle；这里用门闩保持请求，推进明确的虚拟帧间隔，单独捕获加载/悬浮过程。
- [Flutter matchesGoldenFile 字体说明](https://api.flutter.dev/flutter/flutter_test/matchesGoldenFile.html)：测试默认 Ahem 字体显示方块；显式加载中文和 Material 图标字体。

运行前先 `flutter pub get`。捕获不自动更新视觉基线，也不以截图存在代替人工视觉评审；完整矩阵完成后再检查截图中的文字、选中反馈、焦点、遮挡与内容密度。

macOS 若运行磁盘缓存测试时出现 `disk-unavailable`，先检查系统临时目录是否经过 `/var` 等符号链接。缓存协调器有意拒绝链接根目录；可使用 `env TMPDIR=/private/tmp flutter test --no-pub` 指定真实临时目录，无需放宽生产代码中的目录保护。原型捕获使用内存缓存，不依赖这项设置。

手机播放器包含真实字幕偏好编辑器的“大”和“原始 ASS”状态，以及画中画入口与控制层隐藏状态。
画中画隐藏状态通过注入原生事实的测试 backend 驱动同一 Flutter 树，仅验证覆盖层显隐；
它不是系统小窗、原生字幕像素或连续视频／音频证据。系统 PiP 使用隔离 Android 验证包，
由 `tool/android_release_checks.py` 的 `phone_pip_flow` 另验 pinned task、连续会话和变化画面。
