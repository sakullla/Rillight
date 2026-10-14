import 'package:flutter_test/flutter_test.dart' show Finder, find;
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';

/// Real standalone Cupertino host with the application's neutral theme.
/// Tests exercise the same design-library types and Chinese delegates as roots.
class CupertinoTestApp extends StatelessWidget {
  const CupertinoTestApp({
    super.key,
    this.home,
    this.theme,
    this.builder,
    this.locale = const Locale('zh', 'CN'),
    this.supportedLocales = const [Locale('zh')],
    this.localizationsDelegates,
    this.routerConfig,
    this.scrollBehavior,
  });
  const CupertinoTestApp.router({
    super.key,
    required this.routerConfig,
    this.scrollBehavior,
    this.theme,
    this.builder,
    this.locale = const Locale('zh', 'CN'),
    this.supportedLocales = const [Locale('zh')],
    this.localizationsDelegates,
  }) : home = null;
  final ScrollBehavior? scrollBehavior;
  final Widget? home;
  final AppUiThemeData? theme;
  final TransitionBuilder? builder;
  final Locale? locale;
  final Iterable<Locale> supportedLocales;
  final Iterable<LocalizationsDelegate<dynamic>>? localizationsDelegates;
  final RouterConfig<Object>? routerConfig;
  @override
  Widget build(BuildContext context) {
    final data = theme ?? AppUiTheme.light();
    final delegates = [
      AppLocalizations.delegate,
      ...GlobalCupertinoLocalizations.delegates,
      ...?localizationsDelegates,
    ];
    Widget themed(BuildContext context, Widget? child) => AppUiTheme(
      data: data,
      child: Builder(
        builder: (context) =>
            builder?.call(context, child) ?? child ?? const SizedBox.shrink(),
      ),
    );
    if (routerConfig != null) {
      return CupertinoApp.router(
        scrollBehavior: scrollBehavior,
        theme: data.cupertino,
        locale: locale,
        supportedLocales: supportedLocales,
        localizationsDelegates: delegates,
        routerConfig: routerConfig,
        builder: themed,
      );
    }
    return CupertinoApp(
      scrollBehavior: scrollBehavior,
      theme: data.cupertino,
      locale: locale,
      supportedLocales: supportedLocales,
      localizationsDelegates: delegates,
      home: home,
      builder: themed,
    );
  }
}

Finder findAppTooltip(Pattern message, {bool skipOffstage = true}) =>
    find.byWidgetPredicate(
      (widget) =>
          widget is AppTooltip &&
          (message is String
              ? widget.message == message
              : message.allMatches(widget.message).isNotEmpty),
      skipOffstage: skipOffstage,
    );
