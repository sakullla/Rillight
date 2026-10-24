import 'dart:async';

import 'package:flutter/services.dart';
import 'package:rillight/app/ui/ui.dart';

import '../l10n/app_localizations.dart';

/// 长按复制：片名、剧名、发布文件名等名称长按即复制到剪贴板。
///
/// 按住时文字后面浮出一层淡淡的底色作为反馈，松手前不会触发点按；复制后
/// 轻震一下并提示「已复制」。点按手势不受影响，可以包在可点的标题上。
class LongPressCopy extends StatefulWidget {
  const LongPressCopy({
    super.key,
    required this.text,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
  });

  /// 复制的完整文字（显示时可能被省略）。
  final String text;
  final Widget child;
  final BorderRadius borderRadius;

  /// 提示里最多显示的字数，避免一整段文件名撑满提示条。
  static const int noticeLength = 24;

  /// 复制 [text] 并给出震动与提示。供已有长按手势的控件直接调用。
  static Future<void> copy(BuildContext context, String text) async {
    final value = text.trim();
    if (value.isEmpty) return;
    final l = AppLocalizations.of(context);
    final notice = AppNoticeHost.of(context);
    await Clipboard.setData(ClipboardData(text: value));
    unawaited(HapticFeedback.mediumImpact());
    final shown = value.runes.length > noticeLength
        ? '${String.fromCharCodes(value.runes.take(noticeLength))}…'
        : value;
    notice.show(l.copiedText(shown), duration: const Duration(seconds: 2));
  }

  @override
  State<LongPressCopy> createState() => _LongPressCopyState();
}

class _LongPressCopyState extends State<LongPressCopy> {
  bool _pressing = false;

  void _setPressing(bool value) {
    if (_pressing != value && mounted) setState(() => _pressing = value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    return Semantics(
      onLongPressHint: l.copyAction,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressDown: (_) => _setPressing(true),
        onLongPressCancel: () => _setPressing(false),
        onLongPressEnd: (_) => _setPressing(false),
        onLongPress: () => unawaited(LongPressCopy.copy(context, widget.text)),
        child: AnimatedContainer(
          duration: AppMotion.durationOf(context, AppMotion.fast),
          decoration: BoxDecoration(
            color: _pressing
                ? scheme.primary.withValues(alpha: .14)
                : scheme.primary.withValues(alpha: 0),
            borderRadius: widget.borderRadius,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
