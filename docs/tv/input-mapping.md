# Android 遥控器与未来 Siri Remote

本轮不交付 tvOS：没有 tvOS 工程，也没有 `ios/` 或 apple-tv runner。本文只记下核心操作对应，不是实现。

## 核心操作

移动焦点、确认、逐层返回、播放和暂停，不能只靠菜单、触控或电视浏览器完成。

| 操作 | Android 遥控器 | 未来 Siri Remote |
| --- | --- | --- |
| 移动焦点 | 方向键（D-pad） | 滑动 |
| 确认 | Select / Enter | 点击 |
| 逐层返回 | Back，每次一层：先设置对话框，再播放控件，再退出 | Back，同一逐层返回 |
| 播放、暂停 | 媒体键 | 媒体键 |

## flutter-tvos

`flutter-tvos` 是未验证的未来候选。截至 2026-10-03，需求引用包 `1.1.3` 与标签 `v3.47.4-tvos.1.10.3`。该引用不是 Rillight 的验证。

通过 Android TV 验收，不等于 tvOS 播放或输入通过。
