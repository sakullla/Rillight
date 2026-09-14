import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/window_geometry.dart';
import 'package:window_manager/window_manager.dart';

/// 顶栏铬高度,与 window_manager [kWindowCaptionHeight] 对齐。
const double kWindowChromeHeight = kWindowCaptionHeight;

/// Windows/Linux 三个标题按钮的总宽度(每个 46)。
const double kWindowChromeTrailingInset = 46 * 3;

/// 应用按钮与系统 min/max/close 之间的空隙,避免和标题按钮挤成一坨。
const double kWindowChromeActionGap = 8;

/// 顶栏右侧图标与 Windows 标题按钮同高,避免 56px 栏里图标垂下错位。
const BoxConstraints kTitleBarIconConstraints = BoxConstraints.tightFor(
  width: 40,
  height: kWindowCaptionHeight,
);

/// macOS 交通灯占用的左侧留白,供顶栏内容避让。
const double kWindowChromeMacosLeadingInset = 78;

/// 顶栏拖拽的最小位移,避免单击导航被当成拖窗。
const double _kWindowChromeDragSlop = 4;

/// 主窗口:扩展客户区贴上缘,macOS 保留交通灯,最小尺寸 960×540。
///
/// Windows 不走 [TitleBarStyle.normal] 实心标题栏;最大化等由 runner
/// WM_NCHITTEST 返回 HTMAXBUTTON/HTCLOSE/HTCAPTION 等价命中。
const WindowOptions kMainWindowOptions = WindowOptions(
  title: kProductName,
  minimumSize: kMinWindowSize,
  titleBarStyle: TitleBarStyle.hidden,
  windowButtonVisibility: true,
);

/// 是否叠一层标题按钮外观。Linux 可点;Windows 只绘制,命中在 runner。
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

/// 按工作区设最小尺寸、自适应客户区尺寸并居中。须在窗口仍隐藏时调用。
Future<void> applyAdaptiveWindowSize({
  Size minimumSize = kMinWindowSize,
  Size maximumSize = kMaxDefaultWindowSize,
}) async {
  await windowManager.setMinimumSize(minimumSize);
  await windowManager.setSize(
    await resolveAdaptiveWindowSize(minSize: minimumSize, maxSize: maximumSize),
  );
  await windowManager.center();
}

/// 初始化并显示主窗口。播放进程窗口不要走这条路径。
///
/// 接管关闭:系统关窗只触发 `onWindowClose`,由 `MainWindowCloseGuard`
/// 先关闭播放窗口再销毁主窗口。
Future<void> configureMainWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  await windowManager.waitUntilReadyToShow();
  await windowManager.hide();
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: true,
  );
  await applyAdaptiveWindowSize(
    minimumSize: kMainWindowOptions.minimumSize ?? kMinWindowSize,
  );
  await windowManager.setTitle(kProductName);
  await windowManager.show();
  await windowManager.focus();
}

/// 可复用拖拽区:左键移动超过 slop 后 [windowManager.startDragging],双击切换最大化。
class WindowDragArea extends StatefulWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  State<WindowDragArea> createState() => _WindowDragAreaState();
}

class _WindowDragAreaState extends State<WindowDragArea> {
  Offset? _pointerDown;
  bool _dragging = false;

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryMouseButton) {
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
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onDoubleTap: () async {
          if (await windowManager.isMaximized()) {
            await windowManager.unmaximize();
          } else {
            await windowManager.maximize();
          }
        },
        child: widget.child,
      ),
    );
  }
}

/// Linux:包内 [WindowCaption] 可点。Windows:只画外观,交互走 HTMAXBUTTON。
class WindowChromeButtons extends StatelessWidget {
  const WindowChromeButtons({super.key, this.brightness = Brightness.dark});

  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final caption = WindowCaption(
      brightness: brightness,
      backgroundColor: const Color(0x00000000),
    );
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return IgnorePointer(child: caption);
    }
    return caption;
  }
}

/// 主窗口铬宿主:内容铺满上缘,顶带可拖。
///
/// Linux 叠可点 [WindowCaption]。Windows 叠无指针标题按钮外观,系统按钮
/// 由 runner WM_NCHITTEST 的 HTMINBUTTON/HTMAXBUTTON/HTCLOSE 处理,顶带
/// 拖拽等价 HTCAPTION(slop 后再 [windowManager.startDragging])。
/// 标题按钮只占右侧条,其余顶带把单击交给下层。
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
