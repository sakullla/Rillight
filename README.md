# 灯川 Rillight

独立桌面影视客户端。在 Windows、macOS 与 Linux 上连接已有 Emby 服务器，浏览并播放电影与剧集。默认界面为简体中文。

本仓库只包含桌面目标（`windows` / `macos` / `linux`），不含 Android 或 iOS。播放使用 media_kit/libmpv（不是 HTML5 video）。Windows 与 macOS 随应用捆绑 libmpv；Linux 需要系统 `libmpv` 或打包时捆绑。

## 开发

需要已启用桌面支持的 Flutter SDK。

```sh
flutter pub get
flutter run -d windows
flutter test
```
