# 平台播放优化

## Windows

- 修正 `core_decoder.cpp` 中 HEVC Main10、VP9 Profile 0 的本地 DXVA GUID。此前 GUID 与 Windows SDK 不符，支持相应解码能力的 adapter 会被错误拒绝，随后再尝试 FFmpeg 默认设备。新增测试逐项与 SDK 的五个 GUID 比较；修复前 Main10 断言失败。
- `WindowsColorPipeline` 按 polynomial/MMR 和 SDR/scRGB 选择着色器变体，保留浮点精度和映射公式，字节码在进程中按需编译一次。
- 普通 SDR 的 D3D11 解码纹理也使用 GPU 颜色转换和缩放，覆盖 NV12/P010、BT.601/BT.709、全范围/有限范围。SDR 纹理保持 RGBA8，不因桌面支持 HDR 而误报 FP16；导入失败时保留下载到 CPU 的回退。
- 核心输出采用有界纹理租用池，避免每帧创建大纹理/UAV。仅在最后一个帧/呈现器持有者释放后回收。闲置池通常最多三个图像且合计不超过 64 MiB；单张输出超过此预算时仅保留一张当前尺寸纹理，避免 8K RGBA8/FP16 每帧重新分配。尺寸/格式切换清理闲置资源，旧尺寸的迟到归还不进入新池，转换器退出时不因仍有外借帧而保留闲置资源。对外 C ABI 不变，借用纹理仍只在帧存活期间有效。原有返回 COM 引用的独立转换接口不参与复用。
- 大纹理分配移到 FFmpeg immediate-context 锁外。保留跨设备发布前的 GPU 完成确认；没有靠提前返回未完成纹理缩短计时。
- 软件输出的共享帧缓冲池也保留至多一张超过 64 MiB 的大缓冲，避免 8K 输出逐帧分配和触发内存缺页；普通缓冲仍最多两张且合计不超过 64 MiB。输出尺寸变化或会话结束释放缓存，退役会话的迟到帧不重新入池。
- 新增保留多个帧、引用复制、释放后复用、尺寸/格式切换、转换器销毁后读取、HDR polynomial/MMR 切换的像素回归。

## macOS

- 协商 GPU 输出后，VideoToolbox NV12/P010 的 CVPixelBuffer 平面通过 `CVMetalTextureCache` 直接导入 Metal；颜色转换写入有界池中的 IOSurface 输出。支持 SDR、PQ/HLG 和可用的 Dolby Vision RPU polynomial/MMR，保留 Profile 5 缺失 RPU 时的失败边界。
- GPU 输出帧独立持有 CVPixelBuffer，`data` 为空；字幕重绘共享不可变视频纹理。缩放、SAR、四方向旋转、黑边和字幕混合在 Metal 上完成。libass 的裁剪字幕平面仍由 CPU 生成并上传，不下载视频像素。
- SDR IOSurface 交给 Flutter 纹理，扩展线性输出由 Metal 层直接采样。颜色转换完成后再发布跨队列资源；异步呈现额外持有 CoreVideo 缓冲和纹理包装器，直到命令完成，避免关闭/重开与池复用时提前释放。
- 直连诊断为 `cvmetal-direct-sdr` / `cvmetal-direct-linear`。硬件平面不支持、导入或转换失败时，继续只读映射及既有下载/portable 回退；呈现失败可读回已完成的输出并禁用后续直连，单独记录 `gpuPresentationFallbacks`。软件解码和 FEL CPU 重建不称为 GPU 直连。

支持的 VideoToolbox 路径不再执行视频像素的 CPU 映射、颜色转换或上传；回退路径仍存在。纹理直连、实际硬解、窗口画面、物理 HDR/音频效果与性能收益必须分别验证。

## Android

- NV12 使用 GLES 原生归一化纹理的硬件双线性过滤，替代每平面四次整数 texelFetch 与手工插值。P010 仅在设备支持 `GL_EXT_texture_norm16` 时使用对应 16 位过滤，保留全部位深；其余设备继续走整数路径。私有 Surface 和原生 MediaCodec 输出不被强制改成字节上传。
- 用原整数路径作为非均匀缩放参考，新增 P010/NV12、polynomial/MMR1/MMR3 对照，保持最多三个 8-bit 码值的现有颜色误差限制。
- JNI 传递 ABI 12 的解码和源诊断，按 session/timeline 排除迟到快照；只有诊断变化时也推进输出 epoch。
- 诊断使用 `mediacodec` 和 `ffmpeg_threads` 明确区分硬件后端与 FFmpeg 线程配置。原生 Surface 路径显示 `color=mediacodec-surface`，不把封装帧的微小耗时标为颜色转换耗时；未确认最终色彩模式时继续保留未知状态。
- 自有 GLES 的诊断在真正的输出线程采样，显示 `submit`，包含提交与 swap/backpressure 的墙钟耗时，不冒充 GPU 执行时间。核心提前封装 AVFrame 的耗时不再替代这一阶段。


## 回归与验收

- Windows：运行原生 CTest，覆盖 GPU/CPU 颜色对照、跨设备读取、纹理持有/复用/销毁、字幕、启动与时间线。`rillight_decoder_diagnostics_test --benchmark-hdr` 对比合成 scRGB 转换；基准数据单独保存，不作为影片帧率结论。
- macOS：启用 `RILLIGHT_CORE_GPU_TESTS=ON`，运行 `rillight_macos_hardware_video_route` 和 `rillight_macos_color_pipeline`，在目标系统验证 VideoToolbox 映射、FP16 和 RPU 保留、Metal/CPU 回退，以及几何、字幕和窗口生命周期。流程见 `../macos/TESTING_HANDOFF.md`。
- Android：运行 Kotlin 单元测试、原生颜色与故障回退测试。`rillight_android_color_pipeline_test --benchmark` 比较同一设备的过滤与整数路径；不支持扩展时两组可能使用相同回退，不能记为优化收益。JNI 变更还需审核并运行混淆后的 `.validation` Release 测试包。
- 分别记录构建、安装启动、变化画面、物理音频、音画同步与长期稳定性。设备型号、序列号、地址、候选包哈希和运行日志只保存在忽略的证据目录，仓库文档使用通用步骤。
