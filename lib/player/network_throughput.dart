/// 把 mpv `cache-speed`(字节/秒,约 1 秒窗口)格式化成播放器网速文案。
///
/// 这是实际读入缓冲的吞吐,不是片源码率。缓冲写满后会落到 0,与 YouTube
/// Network Activity、mpv stats 的 Speed 一致。单位用 1024 进制,和 mpv /
/// 常见下载器相同。
String formatNetworkThroughput(num bytesPerSecond) {
  final raw = bytesPerSecond.isFinite ? bytesPerSecond.toDouble() : 0.0;
  final bytes = raw < 0 ? 0.0 : raw;
  const kibi = 1024.0;
  const mebi = 1024.0 * 1024.0;
  if (bytes < mebi) {
    return '${(bytes / kibi).round()} KB/s';
  }
  final mebibytes = bytes / mebi;
  if (mebibytes < 10) {
    return '${mebibytes.toStringAsFixed(1)} MB/s';
  }
  return '${mebibytes.round()} MB/s';
}
