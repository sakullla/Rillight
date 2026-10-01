# Android 播放与手机界面记录（2026-10-01）

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
