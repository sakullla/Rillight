# 杜比与实时增强：main 合并及优化验证

> 历史记录：2026-10-09 已按用户要求移除全部画质增强，包括超分、Anime4K、补帧、降噪和锐化。本文增强实现与测试路径不再代表当前功能；最终状态见 [全项目优化报告](global_optimization.md)。


## 合并与修复

- 保留 main 的 Android 隧道播放、私有 YUV Surface、关键帧恢复、位图字幕与设置布局，以及本分支的透传和增强能力。隧道播放继续受 main 的实验开关控制。
- 解决新增帧编号冲突：音频透传保留 7，Android 隧道呈现回执使用 8；macOS 镜像头同步，回归测试断言两者不同。
- 隧道绑定固定 AudioTrack 会话，使用对应的双声道 PCM 契约；普通模式继续按实际路由协商多声道/透传。防止路由协商重建隧道依赖的音频会话。
- Android 首次延迟创建 AudioTrack、切换格式及路由重建时保留音量与静音设置。
- 解码器重开保留 CPU 像素请求，增强开启时退出隧道/私有 Surface；软件回退也能完成该状态切换，避免反复触发恢复。
- 对齐插帧的字幕缓冲区所有权与 main 的共享缓冲区类型；移除已失效的 Android 调试字段引用。设备回退测试目标补齐增强实现及 ncnn 链接依赖。

## 性能、算法和架构

- 未请求模型时不调用其准备入口，避免普通播放及单纯锐化/降噪触发模型校验与加载。
- Filter 和历史帧采用移动所有权；插帧直接读取保留帧，中间帧按需分配；未启用插帧时不保留完整浮点图像。
- 锐化的 3×3 方框滤波改为可分离三行缓冲，合并锐化输出过程。与朴素实现对照，8 位结果误差最多一个量化级，透明度保持不变。
- 修复 FP16 非规格化数转换的指数偏差，保留极暗 HDR 数值。
- 拒绝重复/倒退时间戳之间的历史帧插值；跨时间线及显式重置同样不插值。
- C API 共享请求校验，并验证事实与负载参数，拒绝 NaN 帧率和非法降级标志。
- 将着色器和模型的模块目录、环境覆盖目录查找统一到 `enhancement_assets.h`。Windows 使用宽字符路径和可增长缓冲区，ncnn 使用固定版本提供的宽字符加载接口。

## 联网依据

以下资料在 2026-10-09 访问，并与仓库源码交叉核对：

- [Android AudioTrack](https://developer.android.com/reference/android/media/AudioTrack)：HW_AV_SYNC 时间戳写入、音频会话和轨道接口。用于检查隧道与动态格式协商的边界。
- [Microsoft GetModuleFileNameW](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulefilenamew)：Unicode 模块路径及缓冲区截断行为。用于路径查找修复。
- [固定 ncnn 提交的 net.h](https://github.com/Tencent/ncnn/blob/e54f7b1f88434e1d844ea0551b880a1cfb079ce1/src/net.h)：核实 `load_param(const wchar_t*)` / `load_model(const wchar_t*)`，不依据其他版本推测兼容性。
- [ncnn 错误结果 FAQ](https://github.com/Tencent/ncnn/wiki/FAQ-ncnn-produce-wrong-result)：作为模型处理边界的调研入口；本次没有据此更换模型或宣称推理精度提高。
