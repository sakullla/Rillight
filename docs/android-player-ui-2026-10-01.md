# Android 播放与手机界面记录（2026-10-01）

最新自有 GPU 管线结果见文末“后续 GPU 候选”；下列旧候选的失败记录保留，不代表后续候选结果。

## 范围与边界

开发基准 `04fb83d45486d56860233d601d92705d8cf6c451`；以下 APK 均由该基准上的不同阶段工作树构建，不能把先前通过推广到后续修改。测试设备 PKM110 / Android 16，arm64-v8a，Impeller 开启；只使用独立 `.validation` 包及合成登录。没有修改正式应用数据，没有推送远端。

**杜比性能仍未通过，HDR 60fps 尚无长时间验收结论。** 物理音频、HDR 屏幕实测亮度和色彩均未验证。软件路径输出 SDR，不属于杜比 HDR 输出通过。

## 手机界面

- 轮播图保留横向图片构图，标题和操作位于独立区域；分页点单独置于底部，维持 44dp 点击区，避免按钮与指示器挤在一行。
- 详情图片、标题、元数据和播放操作分层；播放按钮直接显示播放或继续观看的含义，支持长标题和大字体。
- 播放器时间与吞吐放在同一行；快捷操作可横向滚动，“更多”固定可达。二级面板有顶部返回及关闭入口；拖动进度可显示时间。
- Tab 切换保持页面不透明，短距离位移，静态内容有独立绘制边界。手机导航使用实色表面，避免滚动内容透过导航和反复模糊；透明顶栏按主题指定系统图标亮度。

### Profile 真机测量

同一合成界面流程，包含登录、详情播放、屏内锁定、暂停恢复、旋转、后台前台、返回与搜索重试。原生视图、控制操作和播放报告独立验证。物理设备不调用只适用于模拟器的 gRPC 音频捕获，音频记录保持 `unverified / passed=false`。

| 样本 | 帧数 | Build P95/P99 ms | Raster P95/P99 ms | 超过 16.67ms / 11.11ms |
| --- | ---: | --- | --- | --- |
| UI 基线 | 1181 | 9.433 / 15.041 | 9.011 / 12.586 | 12 / 53 |
| 首轮 UI 候选 | 1340 | 8.086 / 14.040 | 8.883 / 11.978 | 13 / 52 |
| 导航与系统栏调整后 | 1270 | 9.189 / 15.997 | 8.326 / 12.056 | 13 / 58 |

这是单次混合流程的样本，样本数量、缓存状态、后台构建负载并不完全相同。最后一行相对于基线的栅格 P95 下降，不证明所有动画稳定 60/90fps，也不证明真实片库性能达标。顶部面板返回、关闭及拖动时间提示在最后一个 APK 之后增加，另有 34 个播放器与交互回归通过。

## 原生播放管线

- MediaCodec 输出直接进入 hybrid composition 的 `SurfaceView`，不再逐帧转 CPU RGBA 再进入 Flutter SDR 纹理。原生字幕由独立 Canvas 图层叠加，保持视频视图在加载期间挂载。
- 不把 opaque MediaCodec 帧传给普通图像字节计算；使用有限队列引用计数。第二帧被误判非法、进而软件回退的根因已有原生回归。
- `avcodec_send_packet` 的 EAGAIN 先排空输出再重试保留的包，不当作硬解失败。
- Surface 销毁期间暂停 Android 视频解码重建，等待替代 Surface，避免临时进入 byte-buffer 模式并终止恢复。
- 去掉 Surface post 后固定 15ms 等待。FFmpeg 的 Android 专用固定补丁传递 PQ/HLG 色彩参数、杜比 MIME 和真实 profile；桌面补丁集合保持原集合。
- `dvh1/dvhe` 被 remux 保留但 dvcC/dvvC 丢失时，在 16MiB、2048 个 packet 上限内读取实际 RPU profile，保留读取的 packet。没有真实配置或 RPU 时不得猜测 Profile 5。
- Android 用实际 MediaCodec 声明的 Dolby Vision profiles 决定是否使用原生杜比 Surface。目标手机查询到 91 个 codec、没有 `video/dolby-vision` 类型；NDK 接受该 MIME 却选择普通 HEVC，早期截图确实偏绿。现对 Profile 5 使用能读取 RPU 的正确颜色路径，但此手机上的软件解码与颜色处理仍未达到性能目标。

### 实际观察

原生 smoke 的最初候选在 Surface 重建失败；等待替代 Surface 后，字幕、重建、seek、重新打开、HLS 和授权范围控制通过。后续 UI profile 包也通过真实控制流程。

HDR60 样本在 1×、1.5× 和 seek 恢复后均有实际变化画面，解码为 MediaCodec。早期同类管线一次 SurfaceFlinger 采样为 BT2020 PQ、126 个有效时间戳，平均 59.814fps、最大间隔 22.36ms；它只绑定当时 APK 和采样窗口，不能推广到整部影片或最终提交。

杜比样本开头缺完整 VPS/SPS/PPS 与 dvcC；恢复实际 RPU 后能进入解码。原生普通 HEVC 路径虽位置前进，但截图偏绿且 seek 早期停帧，因此失败。能力检查后的 RPU 软件路径截图中的衣服恢复蓝色；1×和恢复后有变化，1.5×截图相同且 playing=false，因此整体仍失败。

### 本机证据（ignored build，不随 Git 传输）

| 目录，均位于 `build/android-validation/runs/` | APK SHA256 | 结论 |
| --- | --- | --- |
| `04fb83d-native-surface-smoke` | `12a5b74ddd98acea8f6f0a81654a39c5aa266fc5467520b855d0cf487e05f0eb` | Surface 重建失败，保留 |
| `04fb83d-native-surface-smoke-2` | `c95068a95922d5faac00de74f8b2293adc5c0c72f91055148c801bb273c9ce50` | 原生控制通过，物理声音未验证 |
| `04fb83d-ui-baseline-20261001-174433` | `dc51f293677ebb56ad3889232ef1d3325426fa6fe759ff7824349652de4d8c1e` | Profile UI 控制通过 |
| `04fb83d-ui-candidate-20261001-174704` | `b134dff0f71663afdfce61c126c0e65c0f40e2e51c547c1a4996f85a592184ce` | Profile UI 控制通过 |
| `04fb83d-ui-final-20261001-175836` | `fb4f1128e9587bf24436aadadf6229994d866f72bdafb64528d7db29885dba6c` | Profile UI 控制通过 |
| `04fb83d-dolby-surface-hdr-20261001-174931` | `0b82fcf5dda0390e8a0ff6ce33872d5db0cac2dcd9d99bc9319817822fa69f75` | HDR 变化画面；杜比倍速失败 |

日志：`android-ui-surface-full-tests-quiet.log`（949 通过）、`android-ui-panel-tests-final.log`（34 通过）、`android-ui-surface-analyze-final.log`（通过）、`android-ui-surface-format-final.log`（通过）、`android-core-source-lock-tests-final.log`（3 通过）、`android-release-tool-tests-final.log`（27 通过）。原生 `video_frame_cost_test` 实际执行 exit 0，覆盖 opaque 帧和杜比能力/profile 检查。

先前高负载并行构建期间分别出现磁盘缓存超时和 MP4 索引读取预算失败；没有扩大产品超时以使测试通过。安静条件下全量 949 通过，失败原日志保留。这尚不能排除磁盘繁忙时的产品降级。

## 后续工作

1. 无原生 Dolby Vision 的手机需要保留硬解并读取逐帧 RPU，使用自有色彩呈现管线；不能把慢速软件路径或普通 HEVC 偏绿作为完成。
2. 持续记录 HDR60 实际呈现间隔和长时间掉帧，区分原生 Surface、Flutter UI 与音频；验证退出后手势导航及锁屏唤醒。
3. 真实片库首屏图片加载、连续快速切换和播放器二级操作分别测冷/热状态；不能只看合成样本的 P95。
4. 这里只重建并校验 arm64-v8a SDK。三 ABI Android 发布、Windows/macOS/Linux 新候选运行仍需各自验证；macOS 共用 ABI 8 头文件已同步，Android 专用 API 在其他平台拒绝。

## 后续 GPU 候选

基准 `d024b32`，候选是包含本节的后续提交。PKM110 / Android 16 / Mali-G615 MC6，Impeller 开启；测试仍仅使用 `.validation` 包及合成凭据。原始 APK、逐文件源码 SHA256、SDK 标记、截图和日志保存于 ignored `build/`；文档记录的 APK 哈希绑定测试制品，不能用最终生产 APK 的哈希替换它。

### 实现

- Android 专用固定 FFmpeg 补丁，从真实 HEVC RPU 解析元数据，按输出 PTS 精确关联，支持 B 帧重排。队列有 128 项 / 4MiB 上限；未知 PTS、缺失 RPU、非法 P010 stride/crop/offset/平面长度均拒绝。不会将 Profile 5 的 IPT 作为普通 YUV 显示。
- 没有原生 Dolby Vision codec 的手机保留真实 HEVC MediaCodec 硬解，通过自有 GLES3 管线执行逐帧 polynomial/MMR/IPT-PQ 变换。保留 P010 精度；屏幕和 EGL 均支持时创建 10 位 BT.2020 PQ 原生窗口，否则输出 SDR。
- EGL display 与 Flutter 共用，不执行 `eglTerminate`；呈现器在输出线程持有并在同线程销毁。P010 重挂载只更换呈现窗口，保持解码器、音视频队列及时间线。
- 新 additive API `rillight_core_configure_external_audio_speed` 仅 Idle 可配置，ABI 仍为 8、公开结构布局不变。Android 的源速 PCM 由 AudioTrack 调速并保持音高；倍速保留视频/RPU 和音频队列，不再 seek。音频时钟按源样本时长报告，不能再乘倍速。桌面默认仍使用原 atempo 路径。
- JNI 每源复用有界 64KiB byte array，支持 AVIO 短读；native 线程在其生命周期内复用 JNI attachment，不跨线程共享 JNIEnv。读取锁不阻塞 interrupt。
- P010 seek 使用已有 MediaCodec 的 flush，保留从 in-band 学到的 HEVC 参数。直接 decoder Surface 仍重建 codec，避免已有 Codec2 flush 停帧。每次前后跳转同步 preroll cutoff，避免继承旧值。

### 画面与性能结果

最终 GPU 组合检查：`build/android-validation/runs/d024b32-dovi-gpu-candidate-20261001-203600/result.json`，APK SHA256 `eb9abb48ab2ed34fb9ecd09746aa64cb9de31ba92c537a6d77c6a23efe0fcb4a`。**整体 passed=false，不能称为杜比性能验收通过。**

| 阶段 | 变化画面 | SurfaceFlinger 短窗口 |
| --- | --- | --- |
| HDR60 1× | 通过 | 59.80fps，最大间隔 22.16ms |
| HDR60 暂停 seek 后恢复 | 通过 | 59.64fps |
| 杜比 1×稳态 | 通过，截图无此前整体偏绿 | 24.99fps，P95 54.72ms |
| 杜比 1.5×稳态 | 通过，无旧的 2 秒倍速重定位 | 37.46fps，最大间隔 43.88ms |
| 杜比暂停 seek20 / backward10 后恢复 | 通过 | backward 稳态 24.97fps |
| 杜比原生视图重挂载 | 通过 | 稳态 25.10fps |
| 播放中直接 forward28 | 即时两截图相同，失败；随后恢复 | 最大间隔 2472.67ms，恢复后 25.26fps |
| 杜比退出后重新播放 HDR60 | 通过 | 59.82fps |

原生日志标明 `GLES P010/RPU output=BT2020-PQ-10bit renderer=Mali-G615 MC6`，SurfaceFlinger 视频层为 `BT2020_PQ (163971072)`。这些只证明已选呈现格式和真实短窗口变化画面；没有量测物理屏幕亮度、色准、物理声音，也没有整片持续 60fps 验收。HDR 截图不能代替屏幕光学测量。

### 已确认根因和剩余失败

杜比样本的 23 字节 hvcC 缺 VPS/SPS/PPS。原先每次新建 codec，seek20 首个可用帧却到 23.8 秒，核心按目标时钟等待造成约 4 秒停顿。P010 保留 codec 后首帧准确为 20 秒；临时 PTS 诊断已删除。样本从初始 5 秒打开时仍可能等到首个可初始化的 7 秒帧，该媒体初始化缺口未修复。

播放中 forward28 必须从 23.8 秒随机访问点预解码。诊断候选显示 flush 约 15–34ms，而首个 28 秒帧约 2.3 秒后才产生；等待主要在解码阶段。撤销计数丢弃帧和请求 operating-rate/priority 均没有缩短此时间，未保留在产品代码。后者的自动截图检查曾为 true，但取样晚于停顿，PTS 日志仍为约 2.36 秒，因此没有把该标记当成性能修复。

失败证据保留在 `d024b32-dovi-byte-flush-final-20261001-200936`、`d024b32-dovi-seek-probe-20261001-201849`、`d024b32-dovi-preroll-probe-20261001-202424` 和 `d024b32-dovi-operating-rate-20261001-203037`。这些目录属于实验候选，不能与最终候选互换。当前仍需优化长 GOP 跳转吞吐及杜比帧间隔分布；不通过延长截图等待或降低判定标准消除失败。

### 最终原生控制与手机界面回归

- 原生 smoke：`d024b32-dovi-gpu-native-smoke-20261001-203838`，APK SHA256 `d42c0d7e386d0c58eb1675b54c7de0a4da3851a1573ac459fe0394db0e742c3c`。真实变化彩色画面与控制通过，含字幕、Surface 重建、seek、重开、HLS 和跨源授权范围；物理声音未验证。先前 `195157` 候选漏传 fixture 端口，FFmpeg -11 的配置失败保留，不归为最终管线退化。
- 手机完整 UI：`d024b32-ui-controls-gpu-candidate-20261001-205955`，APK SHA256 `8e919cc68636bb26c18d512d18ca015a5a48241b1348cd04e071c12ef0ee2464`。使用独立 8884 端口及新装验证包；登录、详情播放、屏内锁定、暂停时钟、旋转、后台前台、恢复后的变化彩色帧、返回详情、退出后手势 Home、重新打开、搜索失败重试和播放报告通过。
- Profile UI 1267 帧，Build P95/P99 9.487/14.794ms，Raster P95/P99 9.451/12.227ms，超过 16.67ms 为 15 帧，超过 11.11ms 为 48 帧。混合流程单次采样，不能声称全部动画达到 60/90fps，也没有相同状态的本轮基线可用于宣称 UI 性能提升。
- `d024b32-ui-gpu-candidate-20261001-204026` 安装器等待“继续安装”导致超时；确认安装后 `204505` 使用了仍在运行的旧 8784 合成服务器，其接近 EOF 的历史进度造成重播与暂停检查失败。后续改独立端口和全新状态，原失败未删除。
- `d024b32-ui-isolated-gpu-candidate-20261001-205155` 加入实体锁屏后，安全锁屏使应用生命周期停在 paused，恢复检查超时；用户随后手动解锁。快照仍响应、播放器资源已释放、没有据此确认 ANR 或主线程死锁。**实体锁屏/解锁恢复仍未验证通过**，正常后台前台恢复的成功不能代替它。
- 最终核心/平台源码 SHA256 与 GPU 组合、native smoke 记录逐文件比对一致。`flutter analyze` 通过；固定补丁 C helper 2 项、源码锁 3 项、APK 审计工具 28 项、Kotlin 时钟回归和 Windows 原生核心 6 项通过。未在本轮重新运行 Flutter 全量 949 项；旧候选的全套结果不推广到本轮。

### Windows 候选回归

Windows SDK 与核心从本节候选重建并核验；ABI 8、FFmpeg 9.0.2。核心 `build/windows-android-gpu-candidate-core/librillight_core.dll` SHA256 为 `81c5ebb87664de69fc0a0fc7fac37a283f572b6057a494aec71306760ed8db43`。启用 GPU 检查的 CTest 6 项通过，覆盖 D3D11 色彩、ASS 字幕、音频会话、启动及视频帧成本。

- 两轮 Windows release 主窗口/播放子窗口控制检查通过：`build/player-validation/runs/20261001-210415-481`、`20261001-210551-506`，各自 `result.json` 为 `passed=true`。覆盖跳转、音轨/字幕切换、HLS、错误恢复、退出及显示电源请求释放；日志记录实际 D3D11 decoder。
- 长缓存检查重试通过：`build/player-validation/runs/20261001-211153-942`，`result.json` 为 `passed=true`。覆盖缓存中断恢复及重新打开；早、中、晚三个时段实际窗口截图均有变化，变化像素分别为 14623、12811、17429。证据包含每段两张 PNG 和对应 `window-motion.json`，不能仅以位置前进替代画面检查。
- 首次长缓存运行 `20261001-210817-903` 失败：PATH 选择了没有 Pillow 的 MSYS Python，窗口捕获器报 `ModuleNotFoundError: No module named 'PIL'`，并非已证实视频画面静止。保留原日志；重试明确使用 Windows Python 3.14 / Pillow 12.1.1。
- 检查结束后恢复普通 `lib/main.dart` 的 Windows release 构建，原生依赖审计通过。日志为 `build/windows-android-gpu-candidate-cache-smoke-retry.log` 与 `build/windows-android-gpu-candidate-production-audit-final.log`。

这些结果绑定本节源码候选及上述本机制品，不证明物理声音、Windows HDR 屏幕光学效果或所有真实片库长期性能。macOS/Linux 本轮未编译或运行；Android 长 GOP 跳转和实体锁屏恢复的剩余失败仍按前文保留。
