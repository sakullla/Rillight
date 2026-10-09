# 杜比与实时增强：main 合并及优化验证

> 历史记录：2026-10-09 已按用户要求移除全部画质增强，包括超分、Anime4K、补帧、降噪和锐化。本文增强实现与测试路径不再代表当前功能；最终状态见 [全项目优化报告](global_optimization.md)。

日期：2026-10-09。原分支基线 `b21cbbb`，合入远端 main `e611d44`，合并提交 `195efbb`。范围为本分支新增的音频透传、Dolby Vision/FEL、实时增强及其设置入口。

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

## 性能测量

同一 Windows 主机、MinGW GCC `-O3`，使用 `video_enhancer_test.cpp --benchmark`。基线为 `git show b21cbbb:packages/rillight_player/native/core/video_enhancer.cpp`，候选为本次修改；模型接口为测试替身，测量范围是实际 RGBA 解码、35% 锐化及编码过程。

输入为固定 1920×1080 RGBA 图像，每轮预热 3 帧、测量 15 帧并取中位数，基线与候选交替执行 5 轮。桌面存在其他测试进程，结果用于本机算法对照，非独占机器基准。

| 实现 | 各轮中位数（ms/帧） | 五轮中位数 |
| --- | --- | --- |
| 基线 | 102.147、108.368、112.930、111.730、111.507 | 111.507 |
| 候选 | 84.307、76.686、83.139、78.144、78.240 | 78.240 |

该测试耗时下降约 29.8%。不代表实际播放帧率、RIFE/Anime4K/超分推理加速或硬件性能验收。

## 验证

- Windows 原生核心构建成功，CTest 12/12 通过，包含真实固定模型、播放会话、字幕、颜色转换及新增增强回归。
- Windows 音频路由和调度测试 2/2 通过。
- 增强回归另经 MSVC `/W4 /WX /O2` 编译并运行通过，覆盖 MinGW 之外的编译器检查。
- 将测试程序、核心 DLL 和模型复制到含中文及希腊字符的目录，清除模型目录覆盖后运行：像素/路径回归与真实模型核心测试均通过。
- Android Kotlin 编译、JUnit 54 项通过。
- Android 三种 ABI 的核心、JNI、颜色及增强源码通过 NDK `-Wall -Wextra -Werror -fsyntax-only`；这不等于 APK 链接或设备运行。
- 播放器 Dart 包 13 项测试通过。
- Flutter 静态分析无问题；`flutter test --no-pub --concurrency=2 --reporter expanded` 全量 1,574 项通过、2 项跳过，用时 12 分钟。首次与原生依赖编译并行运行出现超时；低并发复核查询、历史记录和菜单测试 58 项通过，随后全量重跑通过。
- 依赖构建脚本测试 9 项、macOS 构建控制流测试 4 项通过。Linux 发布脚本测试 28 项中 25 项通过、3 项按平台跳过，更新了合并后的 ABI 期望，并保留旧 ABI 拒绝检查。
- 400 个 Dart 文件格式检查及测试集合生成检查通过。桌面 1024px 深色播放倍速设置捕获通过，截图及 manifest 位于 `build/ui-capture/2026-10-09T11-56-21-659Z-lVbZAB/`；仅证明合成界面的外观。

日志和基准原始数据位于忽略目录 `build/merge-*`。本次没有执行 Linux/macOS 实机播放、Android 设备播放、物理音频、HDR 显示或 GPU 稳定性验收。

## 联网依据

以下资料在 2026-10-09 访问，并与仓库源码交叉核对：

- [Android AudioTrack](https://developer.android.com/reference/android/media/AudioTrack)：HW_AV_SYNC 时间戳写入、音频会话和轨道接口。用于检查隧道与动态格式协商的边界。
- [Microsoft GetModuleFileNameW](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulefilenamew)：Unicode 模块路径及缓冲区截断行为。用于路径查找修复。
- [固定 ncnn 提交的 net.h](https://github.com/Tencent/ncnn/blob/e54f7b1f88434e1d844ea0551b880a1cfb079ce1/src/net.h)：核实 `load_param(const wchar_t*)` / `load_model(const wchar_t*)`，不依据其他版本推测兼容性。
- [ncnn 错误结果 FAQ](https://github.com/Tencent/ncnn/wiki/FAQ-ncnn-produce-wrong-result)：作为模型处理边界的调研入口；本次没有据此更换模型或宣称推理精度提高。
