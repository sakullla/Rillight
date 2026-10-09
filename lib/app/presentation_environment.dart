import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:rillight/app/theme/tokens.dart';

enum AppPresentation { desktop, androidPhone, androidTv }

/// Resolved once before assembling routes; width and orientation never select
/// a different product presentation.
class PresentationEnvironment {
  const PresentationEnvironment(
    this.presentation, {
    this.detectionFailed = false,
  });

  static const desktop = PresentationEnvironment(AppPresentation.desktop);
  static const phone = PresentationEnvironment(AppPresentation.androidPhone);
  static const tv = PresentationEnvironment(AppPresentation.androidTv);

  final AppPresentation presentation;
  final bool detectionFailed;
  bool get isDesktop => presentation == AppPresentation.desktop;
  bool get isTv => presentation == AppPresentation.androidTv;

  static Future<PresentationEnvironment> resolve({
    bool? isAndroid,
    Future<bool> Function()? detectTv,
  }) async {
    if (!(isAndroid ?? Platform.isAndroid)) return desktop;
    try {
      final television = await (detectTv ?? _detectTv)().timeout(
        const Duration(seconds: 5),
      );
      return television ? tv : phone;
    } catch (_) {
      return const PresentationEnvironment(
        AppPresentation.androidPhone,
        detectionFailed: true,
      );
    }
  }

  static Future<bool> _detectTv() async {
    final result = await const MethodChannel(
      'com.rillight/environment',
    ).invokeMethod<bool>('isTelevision');
    if (result == null) throw StateError('Missing device presentation');
    return result;
  }
}

class PresentationScope extends InheritedWidget {
  const PresentationScope({
    super.key,
    required this.environment,
    required super.child,
  });

  final PresentationEnvironment environment;

  static PresentationEnvironment of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PresentationScope>()!
      .environment;

  static PresentationEnvironment? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PresentationScope>()
      ?.environment;

  /// 手机界面。没有作用域的独立组件测试按桌面处理。
  static bool isPhoneOf(BuildContext context) =>
      maybeOf(context)?.presentation == AppPresentation.androidPhone;

  /// 页面左右边距：手机 16，桌面与电视 [AppSpacing.page]。
  ///
  /// 详情页共用分区据此与标题、操作按钮落在同一条竖线上。
  static double pageGutterOf(BuildContext context) =>
      isPhoneOf(context) ? AppSpacing.md : AppSpacing.page;

  @override
  bool updateShouldNotify(PresentationScope oldWidget) =>
      environment != oldWidget.environment;
}
