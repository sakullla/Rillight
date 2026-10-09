# 全项目性能与稳定性优化

2026-10-09。最终范围：移除全部画质增强，保留并完善正常解码、HDR／杜比显示、Windows 音频透传、字幕尺寸及全局性能优化。用户暂缓的全屏按钮偶发退出不在本次修复结论中。

## 同步与基线

- 执行 `git fetch origin --prune`，远端 main 从 `e611d44` 更新到 `67df579`。
- 在当前 `feat/dolby-realtime-enhancement` 分支合并 `origin/main`，无冲突，合并提交 `914ad98`。保留前轮默认窗口与首页轮播高度调整；画质增强按用户最终要求移除。
- 本轮基准以 `914ad98` 为基线，不把先前的增强优化收益重复计入。

## 发现与实现

### 聚合查询与作品索引

原 `WorkIndex` 对大量无共同标识的条目也做逐对比较，排序过程中反复生成 JSON 引用键；按来源或旧卡片键寻找分组则扫描整个分组集。聚合控制器的 `sources`、`items`、`works` 等 getter 每次调用都会触发重建，一次页面构建可能重复执行。

新实现：

- 用区域、媒体类型、可靠 provider ID 和完整账号下的 item 引用建立候选倒排索引，仅比较可能有确认边的分组。仍逐对检查未知 provider 冲突、年份冲突等，保留原有贪心顺序、桥接顺序、稳定卡片键和分裂规则。
- 每次重建只生成一次来源键；分组确认边不再重复计算同一 pair 的判断。来源、item 和旧卡片键各有查找映射，item 多版本歧义仍返回 null。
- 数据收取、成员变更、权限撤销时更新索引；正常 getter 复用分组和排序结果。**每次读取仍检查许可和成员资格**，没有把权限检查一起缓存掉。
- 日期和小写标题排序键一次计算，避免在 comparator 内反复扫描来源和分配字符串。

代价是增加与已加载来源/标识数量成正比的索引内存。涉及大量同标识但相互冲突条目的最坏情况仍可能需要二次比较；没有宣称所有输入都变成线性时间。

### 片库首屏与目录缓存

- `BrowseController` 改为立即发起网络请求，并行读取缓存；慢磁盘不再推迟请求发送和在线结果展示。晚到、损坏或属于旧查询的缓存不覆盖新页面。
- 缓存首屏可以先显示，但在线首屏确定游标前不允许继续分页，避免拿旧页游标拼接新页。
- `CatalogCache` 合并同一个 key 的并发磁盘读取，共用原始 JSON 解码结果；单次回归中的 **20 次并发冷查询只执行 1 次磁盘读取**。
- 网络写入、会话切换、失效或磁盘配置改变会让在途旧读取失效；旧读取晚到时不再回填旧内存，也不会因那次旧读取的过期判断去清理已写入的新值。TTL 在磁盘结果实际到达时检查。

没有把手动刷新改成返回网络缓存，也没有更改 HTTP 授权或自动凭据续期策略。

### 播放字节缓存

`SessionByteCache.protectRange` 原先为每个选中块重新扫描整个 LRU 索引，形成 O(N×B) 的区间选择；租约每次读取又线性寻找块。

新实现先收集符合资源、generation 和可用性条件的区间，按起点排序后单次扫描，选择最远终点并保留原插入顺序的平局规则。所选块终点严格递增，后续读取用二分定位到与旧实现相同的第一个覆盖块。

区间获取改为 O(N log N)，单次块定位改为 O(log B)。保留读取副本、预算、保护 pin、磁盘 CRC、资源/generation 隔离和关闭行为；没有通过取消校验或扩大缓存额度换取速度。

## 可复测基准

命令：

```sh
python tool/benchmark_global_performance.py --baseline 914ad98
```

脚本从指定 Git 提交提取旧算法，使用当前工作区作为候选。在同一 Flutter test 进程中，每个场景各预热 2 轮，再交替执行 5 轮并交换先后顺序。每个结果校验分组数或读取字节；以下是五轮中位数。

| 合成场景 | 基线 | 候选 | 耗时下降 |
| --- | ---: | ---: | ---: |
| 1000 条不同作品分组 | 282.396 ms | 9.748 ms | 96.55% |
| 3000 条不同作品分组 | 2451.925 ms | 33.431 ms | 98.64% |
| 1200 条来源、每作品四个来源 | 255.004 ms | 16.546 ms | 93.51% |
| 1024 个缓存块，保护全范围并随机读取 512 次 | 24.867 ms | 4.910 ms | 80.25% |
| 4096 个缓存块，保护全范围并随机读取 512 次 | 216.961 ms | 5.606 ms | 97.42% |

输入构造在计时外；分组计时包含构建索引，区间计时包含保护、读取和释放。区间测试使用 16-byte 内存块，是为了测量索引算法，不代表实际大块拷贝或磁盘 I/O。Flutter test 使用测试 VM，不能直接推断 release 页面帧耗时或端到端播放性能。

基准在全量测试之前单独执行。原始五轮数据、基线提交和候选文件哈希：`build/global-perf/benchmark-1791549466394219300/`。记录之后只对缓存源码补充了等价的 if 花括号以满足 lint，没有更改算法。

## 回归验证

- 40 组固定随机种子，对分页、元数据改动、来源删除/重入、跨区域/类型、未知 provider 和多版本歧义，与旧穷举实现逐项核对分组顺序、稳定键、确认边和引用解析。
- 聚合 getter 连续读取 20 次复用同一结果对象；新分页和成员迁移会更新或移除结果。既有私密锁定、迟到响应、凭据续期、历史和播放许可测试继续执行。
- 24 组随机重叠缓存布局，对随机顺序读取、边界、缺口和资源/generation 干扰逐字节对照旧的扫描规则。
- 目录缓存验证并发去重、写入后旧读回填、过期旧读、账号切换、慢读期间 TTL 到期；片库验证磁盘阻塞时在线加载完成，以及旧游标不会提前分页。
- 完整 Flutter 回归、静态分析、原生与打包检查的最终记录见下文。首轮遇到聚合查询的 100ms 测试时限超时，放宽到 1s 后仍用未完成的门闩确保超时分支实际执行。后续暴露的 Windows 目录清理错误已复现并修复；默认 8 并发还出现本地 HTTP admission 观察窗口与真实辅助进程启动的时序失败，因此最终完整验证采用此前基线相同的 `--concurrency=2`，不把并发 8 的失败日志删除或宣称通过。

## 全部画质增强移除

- 删除通用超分、Anime4K、补帧、降噪、锐化的桌面／手机／TV／独立设置入口、保存字段和控制器命令。旧 JSON 键不参与解析，下次合并写时清除，其他未知键和正常设置继续保留。
- 删除增强像素处理、整帧推理、强制 CPU 画面／解码器切换、显示刷新率监听与增强重试轮询。杜比 FEL 增强层属于原片重建，继续保留；不是被删除的可选画质算法。
- 删除 ncnn、模型、Anime4K shader 源及下载、构建、打包依赖。Windows、macOS 的增量包主动清掉历史模型；Linux 重新创建包后不再复制模型；Android 不再提取或打包模型资产。
- 保持 ABI 10 布局：旧 C 接口只提供兼容响应。非零请求返回失败且不改变播放，模型就绪始终为零，旧像素处理函数直接拒绝；不保留算法或后台任务。Dart／JNI 不再调用这些接口。
- 相比本机前一版测试包，核心 DLL 从 8,649,995 字节缩小到 619,356 字节，移除的模型／shader 资源合计 13,438,196 字节。这是包体测量，不是播放帧率或功耗测量。
- 实际视频／音频状态面板继续显示，包含 HDR／杜比重建、PCM／压缩透传、倍速 PCM 提示和源帧率。

## 下一集出画面后跳过片头

根因在原生 loopback HTTP seek：旧 warm-prefix 响应持有代理唯一的 origin 连接；先打开新 Range 并等待响应头、随后才关闭旧响应，会形成循环等待。改为在同一个 demux 线程先退休旧 AVIO，再打开新 Range。

控制器增加有界 seek 超时、最新 seek 优先、过期操作抑制、单次恢复及暂停意图保留。超时放在串行操作队列之外，不伪造原生操作已经退休，也不让旧集 seek 失败重开当前新集。

`tool/player_seek_probe_test.dart` 用合成媒体、真实 Windows core 和 Dart HTTP transport，在第 2／3 集提供 1MiB warm prefix，等实际解出至少 3 帧后 seek 到 20s，并要求新 timeline、帧 PTS 超过 20.1s。移除增强后的限速 MKV 三轮为 4131／4030／4011ms，均通过。该探针使用模拟展示和音频 sink，只证明原生解码与传输控制，不证明窗口像素或物理声音。另有中断读取／字幕切换的 loopback 核心回归通过。

### Windows 退出收尾

完整回归额外复现了临时通信目录在进程退出后仍被短暂文件句柄占用的问题：`PlayerProcessProtocol.dispose` 的 errno 32 会打断主窗口的状态收尾。对 Windows 的共享冲突、锁冲突和目录未清空错误增加最多 8 次有界重试，其他错误照常上抛。用真实打开的文件句柄先证实旧实现失败，再验证释放句柄后目录清理成功；失败报告快照保留规则不变。这个修复不等于确认用户此前报告的全屏按钮偶发退出根因。

## Windows 音频透传

补齐普通 AC3、EAC3、DTS core，保留 TrueHD/MAT，并新增 DTS-HD 封装路径。立体声压缩流也可按设备能力透传；不再因为声道数小于等于 2 强制 PCM。各格式分别探测 WASAPI 独占能力，按实际采样率与 burst period 打开输出。设备拒绝、独占忙重试耗尽、无法封装或倍速播放时回退 PCM；普通 PCM 仍走共享模式。

- AC3／DTS I–III 的 IEC 61937 长度用 bit，EAC3／TrueHD／DTS-HD 按对应字节规则封装；不把压缩码率混同于载波码率。
- 普通 AC3／EAC3／DTS 不因设备有 Atmos 能力就标成 Atmos。
- AC3／EAC3／DTS：44.1／48kHz × 2／6 声道；TrueHD：48／96kHz × 2／6 声道，共 16 组合成输入，与 FFmpeg SPDIF 输出逐字节一致。
- DTS-HD 为构造包测试；HD-only／Express、当前不支持的采样率或封装组合回退 PCM，不截掉扩展后宣称完整透传。
- 没有接收功放实测，不能断言用户当前播放已经直出、任意 DTS-HD 变种可用或物理 Atmos 已验收。

## 字幕尺寸

用户提供的是 MOV_TEXT 字幕。普通文本字号改为按实际显示画面高度的 4.5% 计算，并保留移动端最小字号；在 1080p 画面中，标准约 48.6、特大约 72.9。ASS 原始样式启用时不高亮不生效的字号；点字号会关闭原始样式，保留用户明确的字号选择，桌面／手机／TV 一致。

Flutter 视口与设置回归、原生 MOV_TEXT 可见像素高度对比通过。原型截图只验证控件和布局，实际字幕栅格化由原生测试覆盖；未把原型中的合成字幕当作用户视频的显示验收。

## 最终验证与本地运行

验证日志保留在 `build/global-perf/`。

- `flutter test --no-pub --concurrency=2 test packages/rillight_player/test`：9 分 59 秒，1,593 项通过、2 项跳过、1 项失败（`removal-full-suite-c2.log`）。失败为 `desktop helper hides lines on one server then private lock rejects a stale writer`：辅助 Flutter 编译超过夹具的启动期限，shell 终止后配置目录清理与尚未退出的子进程发生竞争，报 telemetry 配置路径不存在。不能将本轮全量记为通过。
- 上述失败用例在无其他 Flutter 任务时单独复测通过，1 分 42 秒（`removal-helper-isolated.log`）；没有修改该夹具或放宽其启动期限。单独通过不等于已解决全量并发运行中的时序失败。

- `flutter analyze --no-pub`：无问题。
- 原生 CTest：11／11 通过，包含音频合同、字幕合成／显示、MOV_TEXT、兼容接口拒绝增强。
- MSVC `/W4 /WX`：Windows 音频输出编译及路由／封装单元测试通过。
- Python：依赖构建锁定／历史模型清理 4 项；Linux 打包合同 23 项通过、3 项 POSIX 启动检查在 Windows 跳过；macOS 发布控制流程 4 项通过。后者使用工具替身，不等同于 macOS 原生构建。
- UI 原型：412 宽手机两主题字幕／画面面板 6 张通过；桌面实际输出面板截图通过（`build/ui-capture/2026-10-09T14-38-35-279Z-ibfgFk/`）。
- Windows `tool/player_smoke.ps1`：release 主／子进程播放控制、跨进程设置、关闭后主窗口存活以及实际 UI 线程显示电源请求检查通过，`result.json` 为 `passed: true`。证据为 `build/player-validation/runs/20261009-230613-205/`，执行日志为 `removal-windows-smoke.log`。使用隔离的合成媒体／凭据／设置；本次未使用 `-LongCache`，不能以此宣称已测量变化窗口像素或物理音频。
- 脚本完成后已恢复普通 `lib/main.dart` release 构建；最终依赖审核再次通过（`removal-bundle-verification.log`）。发布目录不含 RIFE、RealESRGAN、Anime4K 旧资源（`removal-bundle-assets.json`）；核心 DLL 与 SDK 一致，SHA256 为 `22a45495f6d7275aff007e8e8158fb93d2f3e2b911824ab1072417c28c0d7f2c`。
- 已启动 `build/windows/x64/runner/Release/rillight.exe`，启动后 5 秒进程存活、Responding 为 true、主窗口句柄非零，PID 16508（`removal-local-launch.json`）。这是本地普通窗口启动证据，不代表用户功放直出或其具体媒体已验收。
- 未执行本次 Linux／macOS／Android 原生设备验收；全屏按钮偶发退出仍按用户要求暂缓排查。

## 联网参考

- [Flutter performance best practices](https://docs.flutter.dev/perf/best-practices)：明确建议避免在频繁调用的 `build()` 中执行重复、昂贵的工作。对应本次移除 getter 触发的分组重算。
- [Dart LinkedHashMap](https://api.dart.dev/dart-collection/LinkedHashMap-class.html)：期望常数时间查找，迭代保留键的插入顺序。对应引用映射以及区间选择时必须保留的原插入顺序语义。

- [Microsoft：IEC 61937 格式表示](https://learn.microsoft.com/en-us/windows/win32/coreaudio/representing-formats-for-iec-61937-transmissions)：WAVEFORMATEXTENSIBLE_IEC61937 的载波与编码采样率／声道字段。
- [FFmpeg SPDIF muxer](https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavformat/spdifenc.c)：AC3／EAC3／DTS／TrueHD burst 构造的独立参考；实际差分使用本机 FFmpeg 9.0.1 工具。

上述资料在 2026-10-09 在线核对。优化是否成立以仓库行为、差分测试和基准为依据，没有仅凭通用建议替换算法。
