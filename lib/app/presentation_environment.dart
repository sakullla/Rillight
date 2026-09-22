import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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

  @override
  bool updateShouldNotify(PresentationScope oldWidget) =>
      environment != oldWidget.environment;
}
