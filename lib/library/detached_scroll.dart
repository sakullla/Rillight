import 'package:flutter/widgets.dart';

/// 横向列表不读写外层页面的 [PageStorage]。
///
/// 详情页用一个 [PageStorageKey] 记住竖向位置。嵌在里面的横滑条如果沿用
/// 这把钥匙，重建时会把竖向偏移读回来，行内容被甩到右边，季选择也会跟着闪。
class DetachedHorizontalScroll extends StatefulWidget {
  const DetachedHorizontalScroll({super.key, required this.builder});

  final Widget Function(ScrollController controller) builder;

  @override
  State<DetachedHorizontalScroll> createState() =>
      _DetachedHorizontalScrollState();
}

class _DetachedHorizontalScrollState extends State<DetachedHorizontalScroll> {
  final _controller = ScrollController(keepScrollOffset: false);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_controller);
}
