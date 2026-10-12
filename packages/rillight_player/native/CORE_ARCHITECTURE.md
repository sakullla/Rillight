# 播放核心架构

## 核心结构

生产构建使用独立 C++ 翻译单元，不再通过一个大文件实现全部流水线。原来的约 6,100 行 `rillight_core.cpp` 缩减为约 1,270 行公共 ABI、生命周期和输出消费代码；私有结构不进入平台插件。

| 文件 | 职责 |
| --- | --- |
| `native/core/rillight_core.cpp` | 公开 C ABI、会话控制、输出帧消费与释放 |
| `core_state.h/.cpp` | 会话状态、时钟、帧队列、实际解码诊断 |
| `core_io.h/.cpp`、`core_loopback.cpp` | 自定义 AVIO、加密读取、取消、密封 loopback HTTP |
| `core_decoder.h/.cpp` | 解码器选择、设备能力探测、硬件格式协商、Dolby 增强层 |
| `core_tracks.h/.cpp` | 流索引、字幕类型、对外轨道能力映射 |
| `core_audio.h/.cpp` | PCM 滤镜、时间戳、速度处理与透传封装 |
| `core_video.h/.cpp` | Dolby 决策、输出尺寸、色彩路径选择、硬件下载与回退 |
| `core_subtitles.h/.cpp` | 内嵌/外置字幕、ASS、位图、裁剪叠加层 |
| `core_decode.cpp` | 音视频包解码、MediaCodec tunnel 与帧投递 |
| `core_session.cpp`、`core_lanes.h` | Demux 会话、取消与时间线屏障、解码和转换队列 |
| `core_frames.h` | 私有帧、缓冲池、转换上下文及其所有权 |
| `video_processing_diagnostics.h` | 按时间线重置的转换路径与处理耗时采样 |

路径均相对于 `packages/rillight_player/`，首行给出完整子目录后，其余 `core_*` 文件同属 `native/core/`。`core_internal.h` 是会话协调层使用的内部汇总入口；解码器、I/O、轨道等实现只引入自身需要的契约。故障注入测试通过测试目录内的 `core_implementation.h` 组合实现，生产构建不使用该入口。

## 已修复的行为

1. **SDR 字幕不再强制全帧回读。** 原来只要选中任一字幕轨，SDR 就关闭 GPU 纹理输出。现在 SDR 和 HDR 都使用裁剪字幕叠加层，由 Windows presenter 叠加；GPU 导入失败时保留既有 CPU 回退。SDR 按其编码空间混合，HDR 按线性光与 SDR 白电平混合。
2. **等待 GPU 时释放解码设备锁。** 资源创建和着色器编译不占用 FFmpeg 的 immediate-context 锁。提交命令与 fence 后释放锁，查询完成状态时短暂加锁；回读先等待完成，再使用 `DO_NOT_WAIT` 映射，CPU 拷贝不占用设备锁。仍保留跨设备共享纹理发布前的完成确认和超时。
3. **软件平面不会无锁复用解码上下文。** GPU 帧切换到 CPU 平面时，转换器明确使用自己的设备/上下文，不再因已有 shader 而继续使用解码器的 shared context。
4. **首帧和后续帧共用色彩回退。** 硬件纹理映射失败后，保留高精度平面与 RPU，下载后尝试现有转换路径；同次 open 不反复尝试已经失败的硬件纹理映射。Profile 5 缺失或无效 RPU 仍然失败，禁止按普通 HDR10 显示。
5. **修复只有帧级线程的解码器启动延迟。** 这类解码器可能在输出首帧前等待多个后续视频包，使交错音频先耗尽有界队列。其线程预算现在保留低延迟行为；支持 slice threading 的 HEVC/H.264 和自带线程池的解码器保留多线程预算。此前 `startup_interleave` 的 seek-gap 首帧失败已通过回归。
6. **诊断来自实际路径。** 解码信息基于已解码帧；增加 `color=gpu-sdr`、`gpu-readback`、`portable-sdr`、`download+…` 等转换路径以及 `convert=…ms`。转换耗时不包含队列/播放时钟等待，不是显示帧率；新时间线会清空样本。新 open 还清空原生源诊断，避免沿用上一片源信息。保持 ABI 12 的既有快照布局。

前两轮 review 的修复保留在当前工作树：关闭旧子进程前保留来源上下文、递归设备锁、ABI 12 的 Python/macOS 绑定、初始化 HLS 过期续期、定期输出样本的解码信息、失败快照在销毁前采集。

## 联网依据

以下页面在本次工作中实际访问，并与固定 SDK 源码及当前实现对照：

- [Microsoft：D3D11 多线程](https://learn.microsoft.com/en-us/windows/win32/direct3d11/overviews-direct3d-11-render-multi-thread-intro)：device 可并发创建资源，device context 的调用必须同步；支持缩短 context 锁范围，而非删除同步。
- [Microsoft：ID3D11DeviceContext::Map](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-map)：`D3D11_MAP_FLAG_DO_NOT_WAIT` 在 GPU 未完成时返回 `DXGI_ERROR_WAS_STILL_DRAWING`。
- [FFmpeg：D3D11VA 设备契约](https://ffmpeg.org/doxygen/trunk/hwcontext__d3d11va_8h_source.html)：设备锁要求可重入，未提供回调时 FFmpeg 安装默认锁。
- [固定 FFmpeg 提交的 Dolby RPU 解析](https://github.com/FFmpeg/FFmpeg/blob/946fcce07b6dcd0331c8cc609192aeff5e1924f8/libavcodec/dovi_rpu.c)：核对 Profile 判定与 RPU 语义。
- [固定 FFmpeg 提交的 HEVC 解码器](https://github.com/FFmpeg/FFmpeg/blob/946fcce07b6dcd0331c8cc609192aeff5e1924f8/libavcodec/hevc/hevcdec.c)：确认 HEVC 同时声明 slice/frame threading 能力。
- [Intel media-driver 能力表](https://github.com/intel/media-driver/blob/master/README.md)：Raptor Lake 家族列于受支持平台、HEVC 10-bit 解码能力表中。该资料属于 Linux media-driver，不能证明用户 Windows 驱动、所选 adapter 或特定码流已成功硬解。
- [libplacebo 的 Dolby 色彩元数据接口](https://github.com/haasn/libplacebo/blob/master/src/include/libplacebo/colorspace.h)：对照 RPU reshape、矩阵与 FEL 残差是不同处理阶段；本次没有引入 libplacebo 或替换自有播放路径。


## 验证入口

平台路径与回归要求见 [平台优化说明](PLATFORM_OPTIMIZATION.md)。性能对照应使用相同输入、输出尺寸和构建模式，分别记录转换、呈现与实际显示；合成测试不能替代物理音频或显示验收。运行结果与设备信息保存到忽略的证据目录，不写入架构文档。
