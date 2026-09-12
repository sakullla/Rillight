import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:rillight/app/product.dart';
import 'package:window_manager/window_manager.dart';

/// 顶栏铬高度,与 window_manager [kWindowCaptionHeight] 对齐。
const double kWindowChromeHeight = kWindowCaptionHeight;

/// Windows/Linux 三个标题按钮的总宽度(每个 46)。
const double kWindowChromeTrailingInset = 46 * 3;

/// macOS 交通灯占用的左侧留白,供顶栏内容避让。
const double kWindowChromeMacosLeadingInset = 78;

/// 顶栏拖拽的最小位移,避免单击导航被当成拖窗。
const double _kWindowChromeDragSlop = 4;

/// 主窗口:隐藏系统标题栏,macOS 保留交通灯,最小尺寸 960×540。
const WindowOptions kMainWindowOptions = WindowOptions(
  title: kProductName,
  minimumSize: Size(960, 540),
  titleBarStyle: TitleBarStyle.hidden,
  windowButtonVisibility: true,
);

/// Windows/Linux 叠包内 [WindowCaption];macOS 只留交通灯。
bool get windowChromeShowsCaptionButtons {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return true;
    default:
      return false;
  }
}

/// 顶栏内容左侧需避开的系统按钮宽度。
double windowChromeLeadingInset([TargetPlatform? platform]) {
  final resolved = platform ?? defaultTargetPlatform;
  return resolved == TargetPlatform.macOS ? kWindowChromeMacosLeadingInset : 0;
}

/// 顶栏内容右侧需避开的标题按钮宽度。
double windowChromeTrailingInset([TargetPlatform? platform]) {
  final resolved = platform ?? defaultTargetPlatform;
  switch (resolved) {
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return kWindowChromeTrailingInset;
    default:
      return 0;
  }
}

/// 初始化并显示主窗口。播放进程窗口不要走这条路径。
Future<void> configureMainWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(kMainWindowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

/// 可复用拖拽区:拖动调用 [windowManager.startDragging],双击切换最大化。
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) {
        windowManager.startDragging();
      },
      onDoubleTap: () async {
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      },
      child: child,
    );
  }
}

/// Windows/Linux 标题按钮:包内 [WindowCaption],透明底,不挡住贴边内容。
class WindowChromeButtons extends StatelessWidget {
  const WindowChromeButtons({super.key, this.brightness = Brightness.dark});

  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    return WindowCaption(
      brightness: brightness,
      backgroundColor: const Color(0x00000000),
    );
  }
}

/// 主窗口铬宿主:内容铺满上缘,顶带可拖,Windows/Linux 叠 [WindowCaption]。
///
/// 标题按钮只命中右侧条,其余顶带把单击交给下层,位移超过 slop 再拖窗。
class WindowChromeHost extends StatefulWidget {
  const WindowChromeHost({super.key, required this.child});

  final Widget child;

  @override
  State<WindowChromeHost> createState() => _WindowChromeHostState();
}

class _WindowChromeHostState extends State<WindowChromeHost> {
  Offset? _pointerDown;
  bool _dragging = false;

  bool _inDragZone(Offset position, double width) {
    if (position.dy > kWindowChromeHeight) {
      return false;
    }
    if (!windowChromeShowsCaptionButtons) {
      return position.dx >= windowChromeLeadingInset();
    }
    return position.dx < width - kWindowChromeTrailingInset;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryMouseButton) {
      return;
    }
    final width = context.size?.width ?? 0;
    if (!_inDragZone(event.position, width)) {
      _pointerDown = null;
      return;
    }
    _pointerDown = event.position;
    _dragging = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_dragging || _pointerDown == null) {
      return;
    }
    if (event.buttons != kPrimaryMouseButton) {
      return;
    }
    if ((event.position - _pointerDown!).distance < _kWindowChromeDragSlop) {
      return;
    }
    _dragging = true;
    windowManager.startDragging();
  }

  void _onPointerEnd(PointerEvent event) {
    _pointerDown = null;
    _dragging = false;
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerEnd,
        onPointerCancel: _onPointerEnd,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (windowChromeShowsCaptionButtons)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: kWindowChromeHeight,
                child: _CaptionButtonHitTarget(
                  trailingWidth: kWindowChromeTrailingInset,
                  child: WindowChromeButtons(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 只把命中交给右侧标题按钮,左侧顶带穿透到内容。
class _CaptionButtonHitTarget extends SingleChildRenderObjectWidget {
  const _CaptionButtonHitTarget({
    required this.trailingWidth,
    required super.child,
  });

  final double trailingWidth;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderCaptionButtonHitTarget(trailingWidth: trailingWidth);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCaptionButtonHitTarget renderObject,
  ) {
    renderObject.trailingWidth = trailingWidth;
  }
}

class _RenderCaptionButtonHitTarget extends RenderProxyBox {
  _RenderCaptionButtonHitTarget({required double trailingWidth})
    : _trailingWidth = trailingWidth;

  double _trailingWidth;

  double get trailingWidth => _trailingWidth;

  set trailingWidth(double value) {
    if (_trailingWidth == value) {
      return;
    }
    _trailingWidth = value;
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (position.dx < size.width - _trailingWidth) {
      return false;
    }
    return super.hitTest(result, position: position);
  }
}
