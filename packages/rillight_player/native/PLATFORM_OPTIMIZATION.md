# 平台播放优化

## Windows

- 修正 `core_decoder.cpp` 中 HEVC Main10、VP9 Profile 0 的本地 DXVA GUID。此前 GUID 与 Windows SDK 不符，支持相应解码能力的 adapter 会被错误拒绝，随后再尝试 FFmpeg 默认设备。新增测试逐项与 SDK 的五个 GUID 比较；修复前 Main10 断言失败。
- `WindowsColorPipeline` 按 polynomial/MMR 和 SDR/scRGB 选择着色器变体，保留浮点精度和映射公式，字节码在进程中按需编译一次。
- 核心输出采用有界纹理租用池，避免每帧创建大纹理/UAV。仅在最后一个帧/呈现器持有者释放后回收，闲置池最多三个图像；尺寸、格式和设备切换不能把旧资源当新资源使用。对外 C ABI 不变，借用纹理仍只在帧存活期间有效。原有返回 COM 引用的独立转换接口不参与复用。
- 大纹理分配移到 FFmpeg immediate-context 锁外。保留跨设备发布前的 GPU 完成确认；没有靠提前返回未完成纹理缩短计时。
- 新增保留多个帧、引用复制、释放后复用、尺寸/格式切换、转换器销毁后读取、HDR polynomial/MMR 切换的像素回归。

## macOS

- VideoToolbox 帧先尝试只读直接映射现有 CVPixelBuffer 平面，转换结束后释放映射，避免 `av_hwframe_transfer_data` 内部的全帧复制。映射不可用时保留原下载回退。固定 FFmpeg 的 `vt_map_from` 会保留帧属性/RPU。
- 已是目标尺寸、无显示矩阵、SAR 为 1 且没有字幕的 FP16 帧，直接交给 Metal 上传，省掉 `_linear` 中间复制；其他几何/字幕情况仍使用既有转换。保留行间距，不再仅为紧密排布而复制；像素着色器维持不透明输出。
- 诊断区分 `mapped+metal-linear` 与 `mapped+portable-linear`，Metal 成功和 CPU 回退不再共用一个标签。


macOS 仍是 CPU 映射/转换与 Metal 呈现的混合管线。完整 CVMetalTextureCache 输出需要独立实现与平台验证。

## Android

- NV12 使用 GLES 原生归一化纹理的硬件双线性过滤，替代每平面四次整数 texelFetch 与手工插值。P010 仅在设备支持 `GL_EXT_texture_norm16` 时使用对应 16 位过滤，保留全部位深；其余设备继续走整数路径。私有 Surface 和原生 MediaCodec 输出不被强制改成字节上传。
- 用原整数路径作为非均匀缩放参考，新增 P010/NV12、polynomial/MMR1/MMR3 对照，保持最多三个 8-bit 码值的现有颜色误差限制。
- JNI 传递 ABI 12 的解码和源诊断，按 session/timeline 排除迟到快照；只有诊断变化时也推进输出 epoch。
- 自有 GLES 的诊断在真正的输出线程采样，显示 `submit`，包含提交与 swap/backpressure 的墙钟耗时，不冒充 GPU 执行时间。核心提前封装 AVFrame 的耗时不再替代这一阶段。


## 回归与验收

- Windows：运行原生 CTest，覆盖 GPU/CPU 颜色对照、跨设备读取、纹理持有/复用/销毁、字幕、启动与时间线。`rillight_decoder_diagnostics_test --benchmark-hdr` 对比合成 scRGB 转换；基准数据单独保存，不作为影片帧率结论。
- macOS：启用 `RILLIGHT_CORE_GPU_TESTS=ON`，运行 `rillight_macos_hardware_video_route` 和 `rillight_macos_color_pipeline`，在目标系统验证 VideoToolbox 映射、FP16 和 RPU 保留、Metal/CPU 回退，以及几何、字幕和窗口生命周期。流程见 `../macos/TESTING_HANDOFF.md`。
- Android：运行 Kotlin 单元测试、原生颜色与故障回退测试。`rillight_android_color_pipeline_test --benchmark` 比较同一设备的过滤与整数路径；不支持扩展时两组可能使用相同回退，不能记为优化收益。JNI 变更还需审核并运行混淆后的 `.validation` Release 测试包。
- 分别记录构建、安装启动、变化画面、物理音频、音画同步与长期稳定性。设备型号、序列号、地址、候选包哈希和运行日志只保存在忽略的证据目录，仓库文档使用通用步骤。
