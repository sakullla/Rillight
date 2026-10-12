# Android 音频与播放调度验证

## Confirmed defects and changes

- Ordinary E-AC-3 used native format ID 3, but Android only mapped IDs 1 and 2.
  Compressed bytes could therefore reach a PCM AudioTrack. Map every known
  native format explicitly and reject unknown formats or untimed compressed
  frames so the core can decode PCM.
- Recognize ordinary E-AC-3 independently of JOC/Atmos and check the active
  route before accepting compressed output. Clear the rejected format's own
  capability bit and retain that rejection on the same route.
- Pass the source output sample rate across JNI rather than assuming 48 kHz.
  Update the JNI constructor, R8 retention rule and APK audit together.
- Use AudioTimestamp to account for hardware presentation latency beyond the
  PCM consumed-frame counter, with bounded timestamp validation and fallback.
  The core can hold its monotonic clock while delayed audio catches up, instead
  of retaining the initial video lead forever.
- Sync staged SDK libraries to the selected ABIs so a previous build cannot
  leave stale native libraries in a single-ABI APK.


## 调度与缓存约束

- 用有界队列和可取消写入维持 AudioTrack 节奏；实际呈现时钟与字节消费计数分别记录，防止迟到音频造成永久时钟领先。
- 后台预读不得阻塞当前播放或 seek。复用读取缓冲、校验缓存与已选轨道索引，同时保留 generation、资源身份、CRC 和用户磁盘预算。
- 已缓存字节范围不代表连续可播放时长，AudioTrack 写入成功不代表物理可闻，解码器重新创建成功也不证明先前故障原因已经消除。
- 遵循实际设备路由能力选择 PCM 或压缩输出；格式或路由拒绝后撤销对应能力，保留音量、静音和音轨选择。

## 验证步骤

使用专用 `.validation` 包与合成媒体，分别验证 PCM、AC-3、E-AC-3、DTS、TrueHD、FLAC、Opus 的声明能力和回退。覆盖格式切换、暂停恢复、seek、下一集、后台前台、Surface 重连、退出与锁屏唤醒。

JNI 变更需同步帧构造器、R8 保留规则与 APK 审核；测试包不能替代日常应用。设备拒绝清理测试数据时，只有专用可丢弃包可通过卸载重装获得干净状态。

音画同步使用已知同步闪光/声音片段，记录呈现时间和听到的声音；使用扬声器、HDMI 或蓝牙时分别确认实际路由。视频、时钟、物理音频、网络与缓存结果分开报告。

原始日志、设备标识、内网地址和包哈希保存到忽略目录。测试与证据格式见 [Android 验证指南](README.md) 和 [发布证据合同](../../tool/player_release_evidence.md)。
