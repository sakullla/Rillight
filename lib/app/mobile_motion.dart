import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/emby/emby_models.dart';

/// 从首页带进剧集页或详情页的那张图。
///
/// 路由本身不改；页面用它在第一帧画上同一张图，避免先黑屏再换一张。
class PhoneImageHandoff {
  const PhoneImageHandoff({
    required this.item,
    required this.preferBackdrop,
    required this.maxWidth,
  });

  final EmbyItem item;
  final bool preferBackdrop;
  final int maxWidth;
}

/// 手机位移和显隐。时长与曲线只取 [AppMotion]。
abstract final class PhoneMotion {
  static const int posterRequestWidth = 400;
  static const int heroRequestWidth = 800;
  static const int pageRequestWidth = 1280;

  static const playerControlsKey = Key('phone-player-controls');

  static Object imageTag(String itemId, {required bool preferBackdrop}) {
    final kind = preferBackdrop ? 'backdrop' : 'poster';
    return 'phone-motion-$kind-$itemId';
  }

  static void openItem(
    BuildContext context,
    EmbyItem item, {
    bool preferBackdrop = false,
    int maxWidth = posterRequestWidth,
  }) {
    context.push(
      AppRoutes.item(item.id),
      extra: PhoneImageHandoff(
        item: item,
        preferBackdrop: preferBackdrop,
        maxWidth: maxWidth,
      ),
    );
  }

  /// 海报或横幅与页面顶部横幅共用一个 [Hero]。
  ///
  /// 飞行中沿用出发时的那张图。减少动效时控制器时长已经是 0，画面直接就位。
  static Widget sharedImage({
    required String itemId,
    required bool preferBackdrop,
    required Widget child,
  }) {
    return Hero(
      tag: imageTag(itemId, preferBackdrop: preferBackdrop),
      transitionOnUserGestures: true,
      flightShuttleBuilder: (context, animation, direction, from, to) {
        return (from.widget as Hero).child;
      },
      child: child,
    );
  }

  /// 播放控件显隐。隐藏后不再接点击，进行中的过渡可以被下一次点按打断。
  static Widget reveal({
    required BuildContext context,
    required bool visible,
    required Widget child,
  }) {
    final duration = AppMotion.durationOf(context);
    return AnimatedOpacity(
      key: playerControlsKey,
      opacity: visible ? 1 : 0,
      duration: duration,
      curve: visible ? AppMotion.standard : AppMotion.exit,
      child: IgnorePointer(ignoring: !visible, child: child),
    );
  }

  static Future<T?> showBottomPanel<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool isScrollControlled = false,
    bool showDragHandle = false,
    bool useSafeArea = false,
  }) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final enter = reduced ? Duration.zero : AppMotion.normal;
    final exit = reduced ? Duration.zero : AppMotion.fast;
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      useSafeArea: useSafeArea,
      sheetAnimationStyle: AnimationStyle(
        duration: enter,
        reverseDuration: exit,
        curve: reduced ? Curves.linear : AppMotion.emphasized,
        reverseCurve: reduced ? Curves.linear : AppMotion.exit,
      ),
      builder: builder,
    );
  }
}
