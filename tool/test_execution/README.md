# 测试执行与耗时

快速、全量、集成分别使用以下命令。计时包含命令启动、pub 检查、测试编译、收集及执行；不清空 Flutter 的增量编译缓存。

```sh
flutter test --exclude-tags integration
flutter test
flutter test --tags integration
python tool/test_execution/benchmark.py
python tool/test_execution/benchmark.py --mode fast --repeat 3
```

基准脚本逐条执行命令，把原始 JSON 日志、通过/跳过数量、最慢用例和总耗时写入 `build/test-timing/<时间>/`。测试失败、无有效用例、运行不完整或超过预算都返回非零；超预算与用例失败分开记录。不要并行启动两条 Flutter 命令：Windows 上正在使用的 native-assets DLL 会阻止另一条命令更新构建输入。

## 实测状态

2026-10-13，Windows 11，i7-9700F（8 核）、32 GB RAM，Flutter 3.47.6 / Dart 3.13.5，测试并发 8。以下为命令启动至退出的实测值，不代表其它机器或 CI。

| 模式 | 通过用例 | 耗时 | 目标 | 结果 |
| --- | ---: | ---: | ---: | --- |
| 原始全量 | 1965 | 303.49s | 20s | 用例通过，超预算 |
| 快速 | 1666 | 66.35s | 20s | 用例通过，超预算 |
| 全量 | 1956 | 83.53s | 20s | 用例通过，超预算 |
| 集成 | 290 | 59.82s | 15s | 用例通过，超预算 |

候选三种命令来自同一次连续基准：`build/test-timing/20261013-005127-581097/summary.json`。Windows 的全量和快速运行各有 2 个原有 POSIX 专用用例跳过。全量比原始命令缩短约 72.5%，但 **20/20/15 秒目标尚未达成**。不以测试进程内部计时替代命令总耗时，也不缓存通过结果或把尚未执行的测试当作通过。

## 组织与覆盖

112 个独立 `*_test.dart` 模块改为 `*_cases.dart`，纳入自动生成的 4 个纯逻辑/HTTP套件、12 个 widget 套件。桌面平台主题缓存会影响滚轮回归，该模块继续独立运行；三服务协议验收保留原来的独立入口及必需场景名称。默认目录共 18 个入口。新普通 `*_test.dart` 仍会正常被 Flutter 发现。

```sh
python tool/test_execution/generate_suites.py
python tool/test_execution/generate_suites.py --check
flutter test test/player/playback_http_proxy_cases.dart
```

较大的模块按注册顺序拆成互不重叠的分片，单独执行模块仍运行它的全部用例。生成器按当前用例数量重新平衡分片，因此修改现有模块的用例数量后也需重新生成，并在 Dart 格式化后执行 `--check`。CI 在安装 Flutter 前检查生成结果。分片数量与生成入口不一致会在收集时失败；新增/删除 case 模块而未更新登记也会失败。HTTP 测试不会与安装 Flutter HTTP mock 的 widget 注册混入同一进程。权重根据当前 Windows 数据分配，模块显著变化后需重新实测。

本次减少默认用例数量的具体处理：

| 处理 | 覆盖保留位置 |
| --- | --- |
| 滚轮渐进移动与 32/64ms 响应合为 1 项 | `app/desktop_scroll_cases.dart`；保留 0/30/32/64ms 断言 |
| 返回按钮 3 个样式 smoke 合为 1 项 | `widgets/desktop_back_button_cases.dart`；同一测试切换浅色、深色及背景图状态 |
| 2 个单独红色调色板用例并入已有双色主题像素矩阵 | `app/content_theme_cases.dart`；保留亮度、主色、错误色及 surfaceTint 断言 |
| hero 尺寸×主题从 6 组缩为 3 组 | `home/hero_artwork_cases.dart`；保留 320/412/1280 宽度及两种主题，调色板另有双色矩阵覆盖 |
| 会启动额外 Flutter 编译进程的桌面 IPC 回归独立执行 | 下节；完整回归保留，移出默认目录 |

前四项减少 8 个重复用例，第五项移出 1 个独立进程用例。认证、来源隔离、私密区域撤销、播放恢复和缓存字节验证仍保留。

业务夹具使用轻量 PIN verifier，访问权威的锁定、撤销与确认逻辑仍是真实实现；独立 PIN 回归继续执行生产 210,000 轮哈希、随机盐、持久化、正确/错误 PIN 与重试限制。重试夹具替换等待调度器，真实套接字、响应、取消和尝试次数仍会执行；生产默认退避、超时和轮询间隔不变。真实文件 mailbox 用注入时钟跨过原始 3 秒确认预算，文件读写和确认处理仍实际执行。

布局/交互测试默认不启用完整无障碍树，已有无障碍断言继续启用；动画中间帧仍绘制，settle 后更新完整语义树。大字节夹具复用有规律的字节数组并按 64 位块精确比较，尾部仍逐字节验证，所有字节都检查。TV 夹具为本地连接设置 250ms 连接期限，避免反复连接已关闭的端口时等待 Windows 默认失败时间。

Windows 真进程回归仍在每次运行时执行启动、ready、命令路由、正常退出和强制结束。仅编译产物缓存于 `build/test-execution/`；helper、协议源码、SDK版本/路径变化会生成新产物，缓存二进制校验不符会重新编译。首次构建成本包含在命令计时内。

## 独立桌面 IPC 回归

```sh
flutter test tool/test_execution/desktop_ipc.dart
```

该用例通过真实文件 mailbox 启动一个独立的模拟播放器 Flutter 进程，验证线路隐藏、私密锁定和迟到写入拒绝。它包含子进程编译，原始全量中单项耗时约 106.66s；因此单列为进程边界验证，不用提高超时或 skip 来伪装快速通过。迁移后的独立入口已单独执行，1 项通过，原始日志为 `build/test-timing/desktop-ipc.jsonl`。

这些检查验证合成协议、Flutter 交互及进程边界，不建立原生视频画面、物理音频或硬件性能验收。
