# 原型 UI 捕获

`node tool/capture-ui.mjs` 用 Flutter 测试渲染器捕获真实桌面、手机和 TV 页面，不启动原生窗口、不需要 SDK、设备或个人 Emby 服务。沿用 cliora 捕获脚本的填充数据、交互后截图与失败汇总思路。这里的播放器画面是合成插画，不是播放验收证据。

需要项目对应的 Flutter、Node 18+ 和支持中文的字体。自动查找系统字体；也可设置 `RILLIGHT_CAPTURE_FONT=/absolute/path/font.ttf`。字体路径与 SHA256 会记入报告，比较两次截图时使用同一字体及 Flutter 版本。

```sh
node tool/capture-ui.mjs
node tool/capture-ui.mjs --platform desktop --theme dark
node tool/capture-ui.mjs --platform phone --out build/ui-capture-phone
node tool/capture-ui.mjs --feature servers --theme light
node tool/capture-ui.mjs --feature aggregation
node tool/capture-ui.mjs --feature 弹幕 --platform phone --size 360
node tool/capture-ui.mjs --only 'poster-hover*,player-settings-*' --platform desktop
node tool/capture-ui.mjs --only server-delete-confirm --theme light
node tool/capture-ui.mjs --only '*loading*' --list
node tool/capture-ui.mjs --only 'provider-*' --platform phone --size 360
node tool/capture-ui.mjs --jobs 2
```

支持 `--platform all|desktop|phone|tv`、`--theme all|dark|light`，默认全部平台和两种主题。`--size` 为配置宽度，可指定 `360,412,1024,1440,1920,3840`。TV 两档都按实机渲染：`1920` 是 1080p 面板（DPR 2），`3840` 是 4K 面板（DPR 4），逻辑画布都是 960×540，截图按物理像素输出，可直接对照实机截图与 4K 下的图片清晰度。`--feature` 支持下表功能名及对应中文别名。`--only` 支持一个或多个状态 ID、`*`/`?` 通配符，逗号分隔；与功能、平台、主题和尺寸筛选取交集。`--list` 列出当前筛选匹配的状态，不启动 Flutter；空结果会报错。

默认输出到忽略目录 `build/ui-capture/`，每次生成独立运行目录，终端给出 `index.html`。截图索引支持平台、主题和状态过滤。`manifest.json` 保存尺寸、状态、字体、版本、结果与缺失清单；`capture.log` 保留完整日志。失败返回非零退出码，保留已完成截图。手机横屏的 `profileWidth` 仍是竖屏配置宽度，`width`/`height` 为图片实际尺寸。`theme` 是应用主题，`renderedTheme` 说明播放器固定使用深色。

尺寸和主题组合由一条 `flutter test` 命令并发执行，每个组合独立测试进程；默认并发为 CPU 数量的一半（最少 1、最多 4），可用 `--jobs N` 调整，`--jobs 1` 用于串行排查或内存较少的机器。所有所选状态仍实际执行，失败和缺失检查不变。临时入口保存在本次输出的 `drivers/` 下，`manifest.json` 的 `timing` 记录实际并发、分片数量、Flutter 执行及报告生成前的总耗时。不要同时启动多条 Flutter 命令，尤其在 Windows 上会争用 native-assets DLL。

截图沿用原有动画帧和图片取色等待，使用完整分辨率及真实阴影。捕获无需无障碍断言，不在每帧构造无障碍树；本机密码使用内存验证夹具，真实密码哈希和持久化由测试套件覆盖。不要用降低分辨率、漏拍状态或复用旧截图来比较提速。PNG 直接编码未预乘的 RGBA 像素，保留 sRGB 标记，使用无损 Deflate level 1 与固定行过滤，减少保存开销；代价是输出文件变大（详情矩阵实测约增加 59%）。跨编码器比较应解码后比较像素，PNG 文件哈希本身会改变。

| 功能 | 主要状态 |
| --- | --- |
| `home` / 首页 | 两帧加载过程、内容、货架、鼠标悬浮过程、遥控焦点、手机首页编辑、桌面顶栏媒体库下拉 |
| `aggregation` / 聚合 | 真实三端入口、逐服横排、锁定占位及进入密码、继续观看／收藏／媒体库、逐服空态、局部失败与搜索 |
| `library` / 片库 | 片库列表、电影/剧集片库、排序、筛选、继续观看及最新入库列表 |
| `detail` / 详情 | 电影、剧集、季、分集、两季并排季标签与多季剧折叠季入口及其下拉/单选表/TV 列表、选集弹窗、分集右键菜单、音轨和字幕选择、剧照查看器与翻页 |
| `search` / 搜索 | 初始、输入、结果、空结果、筛选、TV 输入弹窗 |
| `servers` / 服务器 | 账户、服务器管理、线路新增/编辑、删除确认、重命名、密码及校验、新增服务器/高级设置 |
| `settings` / 设置 | 各折叠分组、主题/倍速/缓存/解码下拉、弹幕配置与高级设置；三端更新检测、自动提醒开关、版本忽略、启动更新提醒弹窗、新版、下载、校验、缺包、安装/网页失败及 Android 来源授权 |
| `login` / 登录 | 已保存服务器（桌面另有多线路展开）、地址校验、高级设置、主题菜单、TV 输入 |
| `player` / 播放器 | 加载、缓冲、暂停、进度预览、手机锁定、横竖屏设置、字幕、片源、倍速、跳过片头/片尾、续播、选集、下一集、结束、错误 |
| `danmaku` / 弹幕 | 样式、开关、高级设置、关键词、匹配搜索/加载/结果/选集/空结果/失败/成功，含手机横屏 |

各端按真实能力捕获：TV 当前没有弹幕入口、手机式首页编辑或桌面式应用设置；手机首页单库入口、TV 媒体库与桌面首页片库入口分别记录。桌面「...」打开首页区块编辑。`scenarios.json` 的 `platforms` 是明确的适用范围，非适用组合不会冒充已捕获。播放器直接按保存进度续播，没有虚构的续播确认弹窗。原生窗口菜单、外部网站/系统文件选择器不在原型范围。

通过真实点击、悬浮或按键打开交互状态；页面路由可直接定位以减少串联依赖。捕获保留指针和焦点。状态缺失、点击未命中、Flutter 异常和布局溢出均导致失败。新增状态同时维护 `scenarios.json` 与对应场景；截图文件名稳定，输出目录隔离。

所有账号、偏好、图片缓存与播放器均为内存夹具。插画由捕获工具绘制，不依赖外网图片。捕获脚本位于 `tool/`，不会加入默认测试收集。PNG 与索引是原型呈现证据，不证明平台原生能力、实际视频、声音或硬件性能。

`provider-*` 从三端真实服务入口捕获 Emby、Jellyfin、Plex 登录、错误、连接后首页和播放器加载/完成。Jellyfin Quick Connect、Plex 授权码、自有/共享服务器发现及 Home PIN 使用独立协议 fake 的回环 HTTP 服务；Emby 使用注入协议适配器。TV 文本输入使用实际遥控编辑器。播放器仍使用合成后端，这些截图不证明解码或真实服务兼容性。

## 参考与实现取舍

三端筛选、手机布局与缓存显示的设计依据见 [UI/UX 重设计说明](UX_REDESIGN.md)。捕获覆盖从首页实际点进详情的加载／完成帧，并检查主操作的位置；播放器另有下载中与速度归零后的缓存区间截图。

2026-10-02 联网查阅以下官方资料：

- [Playwright Visual comparisons](https://playwright.dev/docs/test-snapshots)：截图随系统、字体及环境改变；记录宿主、Flutter 版本、字体路径及哈希，不把跨环境像素差异当成 UI 回归。
- [Playwright Best practices](https://playwright.dev/docs/best-practices)：隔离状态、控制测试数据、使用稳定定位和可交互性检查。这里使用实际页面的 Key、语义/标签定位与内存数据，缺少入口或点击被遮挡就失败。
- [Flutter pumpAndSettle](https://api.flutter.dev/flutter/flutter_test/WidgetTester/pumpAndSettle.html)：持续加载动画无法 settle；这里用门闩保持请求，推进明确的虚拟帧间隔，单独捕获加载/悬浮过程。
- [Flutter matchesGoldenFile 字体说明](https://api.flutter.dev/flutter/flutter_test/matchesGoldenFile.html)：测试默认 Ahem 字体显示方块；显式加载中文和 CupertinoIcons 图标字体。

运行前先 `flutter pub get`。捕获不自动更新视觉基线，也不以截图存在代替人工视觉评审；完整矩阵完成后再检查截图中的文字、选中反馈、焦点、遮挡与内容密度。

macOS 若运行磁盘缓存测试时出现 `disk-unavailable`，先检查系统临时目录是否经过 `/var` 等符号链接。缓存协调器有意拒绝链接根目录；可使用 `env TMPDIR=/private/tmp flutter test --no-pub` 指定真实临时目录，无需放宽生产代码中的目录保护。原型捕获使用内存缓存，不依赖这项设置。

捕获使用自带的测试绑定开启真实投影。Flutter 测试默认关闭阴影，会把 `BoxShadow` 画成无模糊的实色块，浅色页面上看起来像卡片底下多了一条灰边；这里的截图因此与实机的弥散投影一致。

手机播放器包含真实字幕偏好编辑器的“大”和“原始 ASS”状态，以及画中画入口与控制层隐藏状态。
画中画隐藏状态通过注入原生事实的测试 backend 驱动同一 Flutter 树，仅验证覆盖层显隐；
它不是系统小窗、原生字幕像素或连续视频／音频证据。系统 PiP 使用隔离 Android 验证包，
由 `tool/android_release_checks.py` 的 `phone_pip_flow` 另验 pinned task、连续会话和变化画面。

`--feature entry` captures the compact film-source selector before verification, its password form and privately verified candidates, plus the recoverable startup history failure page. Synthetic paths identify retained files; these captures do not establish native playback or device acceptance.

## 2026-10-20 性能对比

Windows 11、Flutter 3.47.7、同一微软雅黑字体，`--feature detail` 的完整三端／双尺寸／双主题矩阵：修改前 204.904 秒，优化后默认 4 路并发 85.460 秒，缩短约 58.3%。两次均为 204 张且无缺失；202 张 PNG 哈希完全相同，另两张浅色分集详情只有背景取色各通道最多 1 级差异，布局和内容一致。没有降低分辨率、阴影质量或减少状态。

对比目录为 `build/ui-capture/2026-10-20T14-10-29-336Z-9RYEqP/` 与 `build/ui-capture/2026-10-20T14-18-50-997Z-D4lbs9/`。数字为该机器单轮命令总耗时，完整默认矩阵的耗时另行记录，不能按图片数量线性外推。

完整默认矩阵实测 685.724 秒（11 分 26 秒），24 个测试全部通过，2408 个唯一状态无缺失。日志共 2412 次截图，手机 `account` 在同一流程中重复保存，按文件／状态去重后仍为 2408；没有漏掉注册状态。报告位于 `build/ui-capture/full matrix & audit/2026-10-20T14-33-13-221Z-U83n3y/index.html`，本次也验证了 Windows 输出路径包含空格和 `&`。原交付报告在 1900.7 秒时超时，属于未完成的历史记录，不用它计算同覆盖率的加速百分比。


第二轮保留原有帧时序，改用快速无损 PNG 编码。完整默认矩阵从 685.724 秒降到 **532.340 秒（8 分 52 秒，再缩短约 22.4%）**；24 个测试通过，2408 个唯一状态无缺失，重复 `account` 记录与上一轮一致。报告：`build/ui-capture/2026-10-20T14-59-42-045Z-sINrZJ/index.html`。数据仍为同机器单轮测量。

保存阶段的 4K 详情分组从约 9.5 秒降至 4.2 秒，但详情小矩阵命令总耗时本轮为 90.993 秒，未优于上一轮 85.460 秒；不能将编码阶段收益当成每个筛选任务的固定加速。该矩阵 204 张图片中 203 张解码像素完全一致，另一张最多 1 级色值差异。缩减中间帧的实验会改变部分手机截图，未采用。

完成态额外检查：全量像素对比发现服务首页的异步封面偶尔仍为占位图，随后增加了有超时的可见图片解码检查，仅用于 `provider-*-connected`，加载态不受影响。三端／双尺寸／双主题的 36 个完成态已通过。上述 532.340 秒全量计时在增加此检查之前，最终版本的全量复测尚未完成，不据此声称其精确耗时。
