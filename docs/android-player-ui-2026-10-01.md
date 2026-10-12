# Android 播放与手机界面验证

## 手机界面

- 轮播图保留横向图片构图，标题和操作位于独立区域；分页点单独置于底部，维持 44dp 点击区，避免按钮与指示器挤在一行。
- 详情图片、标题、元数据和播放操作分层；播放按钮直接显示播放或继续观看的含义，支持长标题和大字体。
- 播放器时间与吞吐放在同一行；快捷操作可横向滚动，“更多”固定可达。二级面板有顶部返回及关闭入口；拖动进度可显示时间。
- Tab 切换保持页面不透明，短距离位移，静态内容有独立绘制边界。手机导航使用实色表面，避免滚动内容透过导航和反复模糊；透明顶栏按主题指定系统图标亮度。


## 播放验收

使用专用 `.validation` 包与合成登录，分别检查手机、TV 的操作树、旋转、锁定、暂停恢复、字幕、Surface 重连、退出后导航及锁屏唤醒。

Profile 5 必须保留并正确使用 RPU；原生 Dolby、GPU SDR/PQ 映射、软件回退需要分别记录。原生 Surface 回调不等于正确颜色或物理声音。实时性能比较须固定媒体、窗口/输出尺寸、构建模式和缓存条件。

运行与设备数据不保存在此文档。详见 [Android 验证指南](../integration_test/android/README.md)、[原生回归](../packages/rillight_player/native/core_tests/android_playback_checks.md) 和 [平台优化说明](../packages/rillight_player/native/PLATFORM_OPTIMIZATION.md)。
