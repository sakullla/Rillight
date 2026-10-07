# 桌面核显界面与空闲 CPU 优化

本次针对滚动、页面切换和交互浮层的渲染开销，不改变视频解码设置。

## 联网依据（2026-10-04）

- [Flutter Performance best practices](https://docs.flutter.dev/perf/best-practices)：减少离屏缓冲、透明合成和重复绘制；静态效果可以预计算并缓存；列表使用懒加载。
- [BackdropFilter API](https://api.flutter.dev/flutter/widgets/BackdropFilter-class.html)：背景模糊会重新处理背后的内容，代价较高；单张图片滤镜应使用自己的图片处理链。现有桌面顶栏没有 BackdropFilter，不能把日常滚动卡顿直接归因于毛玻璃。
- [Flutter performance profiling](https://docs.flutter.dev/perf/ui-performance)：分别检查 UI 和 raster 线程；用实际设备的 profile/release 模式评价性能，debug 模式和测试截图不能证明正式版帧率。
- [ScrollPositionWithSingleContext.pointerScroll](https://api.flutter.dev/flutter/widgets/ScrollPositionWithSingleContext/pointerScroll.html)：默认直接改变位置，取消已有滚动活动；官方实现中的 `forcePixels(targetPixels)` 解释了离散滚轮的逐格跳动。
- [ScrollPosition.animateTo](https://api.flutter.dev/flutter/widgets/ScrollPosition/animateTo.html)：位置动画可被手动滚动或其它活动打断，到达边界后正常结束。滚轮时长、距离倍率和精细位移阈值是本项目的交互策略，不是 Flutter 官方建议值。

## 修改及边界

首页空闲 CPU 还存在一个明确的持续绘制来源：桌面轮播圆点把 7 秒倒计时交给 TweenAnimationBuilder，每个屏幕刷新周期都驱动布局和绘制，即使没有鼠标交互。桌面现在显示静态选中圆点，保留每 7 秒的自动换图、悬停/滚动暂停和手动切换。加载完成、两次换图之间不再为倒计时持续安排帧。回归测试直接检查没有运行中的动画、没有已安排帧；这证明该持续帧来源已移除，不能证明截图中全部 11.3% CPU 都来自它。目标核显仍需比较空闲 60 秒的进程 CPU 和页面操作表现。

1. 海报回退背景原先先铺满横幅，再通过 ImageFiltered 和 Opacity 模糊合成。`cacheWidth: 160` 只限制输入解码，不能限制横幅滤镜的离屏范围。现在先按横幅比例裁剪，在最长边不超过 160 像素的画布上生成模糊 PNG，再作为普通图片显示。模糊半径按缩放比例换算，透明度直接应用于图片。源图解码同样限制最长边；缓存以图片字节对象为弱键，每张图片最多保留 4 种窗口尺寸结果。
2. 桌面页面使用 NoTransitionPage，避免页面切换期间同时对两棵海报树做整页动画合成。保留路由 key、名称、参数和返回导航。手机/TV 路由保持原有策略。
3. 桌面内容与顶栏各自设置 RepaintBoundary，阻断顶栏交互、内容滚动互相引起的绘制传播。这仍不意味着整个内容树不再绘制。
4. profile/release 桌面窗口订阅 Flutter FrameTiming：最近连续的 12 帧中，8 帧 raster 耗时超过显示器刷新周期时，启用现有减少动态效果路径。超过 500ms 的空闲间隔清空样本；只看 build 耗时、单帧尖峰或零散慢帧不会触发。触发后停止监测并保持到窗口销毁，避免反复切换。MediaQuery 包装始终存在，页面、滚动位置和焦点不会因降级重新挂载。系统减少动态效果偏好始终保留。
5. Windows/Linux 的离散滚轮位移原先逐次直接应用到页面，图片已经加载也会出现逐格跳动。每个桌面路由现在拥有独立的主滚动控制器，片库使用同类控制器；同方向连续滚动累加目标，反向滚动取消先前剩余距离，程序跳转中止滚轮动画，边界停止。第二个测试包的 120ms 过渡仍有拖沓感，0.1.41 将过渡缩短到 60ms，离散滚轮距离提高到系统位移的 1.6 倍；时序回归检查 32ms 内完成至少 85% 位移，64ms 内停止，连续输入后也没有长尾。小于等于 8 逻辑像素的精细位移沿用原行为，macOS 和手机/TV 沿用平台滚动方式。横向货架上的垂直滚轮转发到页面的 `pointerScroll`，避免 `jumpTo` 绕过平滑路径。系统减少动画时保留相同的离散滚轮距离并即时滚动；自动性能降级保留用户原本的滚动偏好。
6. 修正首个测试包的视觉回归：`disableAnimations` 曾同时将静态遮罩透明度提高到至少 0.85，顶栏和详情背景叠加后接近纯黑，渐变尾部还会进入标题区域。现在只有系统高对比度偏好会提高静态遮罩透明度，减少动画或自动性能降级不再改变背景亮度。卡片在减少动画时也停止阴影过渡与模糊阴影，保留焦点环。

这组阈值是产品降级策略，不是 Flutter 官方推荐值或核显性能测量结论。降级减少轮播、骨架动画和毛玻璃等可选效果，不解决所有可能的 UI 线程、驱动或网络瓶颈。debug 模式默认不启用自动降级。

## 复核

Windows 关闭路径另外修正了原生退出顺序：`window_manager.destroy()` 只发 `WM_QUIT`，原先消息循环结束后先 `CoUninitialize()`，FlutterWindow 和渲染器随后才随栈析构，且主窗口始终显示到清理完成。现在 Dart 主窗口关闭守卫完成播放器清理后，原生消息循环退出时先隐藏窗口，显式销毁窗口/Flutter 引擎，再反初始化 COM。保留关闭守卫的播放器停播、快照补报和超时处理；没有以强制结束整个进程替代清理。此处已确认的是代码的生命周期顺序，核显机器上的关闭耗时改善仍需实测。

第二个 Windows Release 候选在本机使用三个独立的 `RILLIGHT_VALIDATION_DIRECTORY` 启动到未登录页，通过 `WM_CLOSE` 走正常关闭守卫：窗口消失为 41.1、225.6、89.8ms，进程结束为 159.7、553.9、229.4ms，三次退出码均为 0。包内 `native-idle-launch-close.json` 记录样本。这是本机候选的空闲启动/关闭证据，没有旧版对照，不能证明核显首页或播放中关闭的改善，也不建立视频/物理音频验收。

```powershell
flutter analyze
flutter test
node tool/capture-ui.mjs --only 'home-ready,home-display,poster-hover-transition,movie-detail,series-detail,login-saved-servers' --platform desktop --size 1024 --theme all
```

回归测试使用合成帧耗时验证触发、保持、空闲重置、关闭监听和系统偏好，并检查元素未重新挂载。图片测试检查高 DPI 大横幅输出仍为 160×80、实际颜色混合、缓存复用、窗口变更、错误输入和异步销毁。导航测试检查桌面路由切换/返回时长为零；已有应用集成测试继续覆盖页面切换和服务器切换。

第二个测试包增加实际滚轮事件回归：逐帧位移、连续输入距离、反向响应、精细输入、程序跳转打断、边界停止、系统偏好、自动降级和路由主控制器。另检查性能降级前后的真实 AppShell 顶栏与背景渐变完全一致，减少动画时按钮底衬透明度保持正常，高对比度模式仍增强对比度。标准 Flutter 分析、定向测试和全量测试的执行结果写入包内 manifest；此前沙箱受限时的失败日志不作为通过证据。

目标核显仍需实际验证：使用同一设备、驱动、窗口尺寸/DPI、刷新率、媒体数据与缓存状态，分别运行基线和候选 profile/release 构建。各记录至少 60 秒的首页上下滚动、片库快速滚动和反复详情进出，比较 UI/raster 帧耗时与超过刷新周期的帧比例，并观察自动降级后交互和文字可读性。按 `tool/player_performance_checks.py` 的现有格式保存性能样本；截图、合成 FrameTiming 测试与独显机器的通过结果均不能代替核显测量。


## 2026-10-07：首页与媒体库分类纵向滚动

已复现的共用故障：连续滚轮输入每帧替换 `DrivenScrollActivity`，新 ticker 的第一帧总从零开始。新增测试每隔 16ms 输入一次，不额外插入零时长帧，基线在连续输入期间的位置仍为 0。现在一个滚轮序列共用 ticker，后续输入更新目标和插值起点；保留 60ms 收尾、1.6 倍距离、反向取消剩余距离、精细输入和系统减少动画偏好。

同时减少以下开销：

- 图片加载完成后取消逐像素滚动监听；未完成图片仍跟踪内外层视口，以处理优先级、取消和重试。
- 首页片库预览在目录控制器中复用已解析的数据和进行中的请求，懒加载行销毁后滚回不再重复请求。刷新、账户/线路变化、TTL 和请求失败仍会失效缓存。
- 桌面剧集详情把分集放入父滚动视口的懒加载列表；远距离选集按已布局行估算位置，再对齐实际目标。滚回当前集不会因为重新挂载而自动跳转。
- 聚合的继续观看、收藏、媒体库分别发布结果，单个慢模块不阻塞同服务器其他模块；最多并行加载三台服务器。页面按需构建服务器行，三个模块分别保存滚动位置。

验证环境为 Windows、Flutter 3.47.6。以下 73 项定向测试通过，包含真实首页和媒体库分类组件上的连续纵向滚轮、存活海报不重建、图片队列/缓存、首页刷新、聚合失败重试、200 集列表定位与分集加载更多：

```powershell
flutter test --no-pub test/catalog/shelf_grid_scroll_rebuild_cases.dart test/app/desktop_scroll_test.dart test/home/library_latest_row_test.dart test/aggregation/server_sections_test.dart test/library/episode_list_scroll_test.dart test/catalog/item_detail_cases.dart test/widgets/media_image_cases.dart
```

另有手机首页编辑和聚合页滚动导航两项回归通过，共 75 项定向检查通过。

全量测试修复同时处理了以下问题：测试平台对系统方向/UI 请求的异步应答与假时钟竞争（补齐平台桩，不在纯 HTTP 套件初始化 widget binding）；搜索提交、服务器分组、海报与季图片的过期断言；顶栏下方控件的实际点击位置；TV 遥控器目标定位和来源限定的分页入口。TV 首页在横幅为空、隐藏或不是首栏时为顶部导航留出空间，继续观看入口不再被遮挡，并断言该入口可实际命中。Windows 全页滚轮回归单独运行于测试 isolate，避免其他平台用例已缓存的 ThemeData 干扰。桌面模拟播放器的启动器在等待子进程编译时续写心跳，避免编译超过 15 秒后被子进程误判为父进程失联；原有超时保持不变，子进程启动时额外断言心跳有效。测试消息只有在 JSON 完整且文件可删除时才被消费；Windows 写入句柄尚未关闭或消息写到一半时保留文件，等待下一次有限轮询，并有真实文件句柄的回归测试。

格式检查及套件注册检查通过，静态分析零问题。最终 `flutter test --no-pub --reporter expanded` 全量 1,482 项通过，耗时 7 分 26 秒；结果记录在 `build/release-v0.1.43-full-tests-verified.log`。静态分析日志为 `build/release-v0.1.43-analyze-final.log`，格式日志为 `build/release-v0.1.43-format-final.log`。

实际组件捕获已得到首页、媒体库分类、聚合和剧集详情的明暗主题图片；捕获脚本随后在既有聚合管理/媒体库范围入口以及详情菜单关闭步骤失败，详情菜单关闭失败也已在未修改基线复现，完整捕获矩阵未通过。这些图片仅用于查看布局。尚未测量目标机器 profile/release 的 UI/raster 帧耗时，不给出帧率或硬件性能提升百分比。


TV 定向捕获 `node tool/capture-ui.mjs --only 'home-ready,tv-home-section-move' --platform tv --theme dark` 已通过，结果位于 `build/ui-capture/2026-10-07T05-08-38-443Z-1lu9U5/`（首页与栏目调整两张图）。这仍然只是合成数据下的组件布局证据。
