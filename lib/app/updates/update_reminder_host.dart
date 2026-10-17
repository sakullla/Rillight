import 'dart:async';

import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../player/player_window_host.dart';
import '../l10n/app_localizations.dart';
import '../ui/ui.dart';
import 'update_check.dart';
import 'update_controller.dart';
import 'update_scope.dart';

/// Read at the instant the user requests installation, including desktop opening.
class UpdateActivityScope extends InheritedWidget {
  const UpdateActivityScope({
    super.key,
    required this.playbackOccupied,
    required super.child,
  });
  final bool Function() playbackOccupied;
  static bool playbackOccupiedOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UpdateActivityScope>()
          ?.playbackOccupied() ??
      false;
  @override
  bool updateShouldNotify(UpdateActivityScope oldWidget) =>
      playbackOccupied != oldWidget.playbackOccupied;
}

class UpdateReminderHost extends StatefulWidget {
  const UpdateReminderHost({
    super.key,
    required this.router,
    this.playerHost,
    required this.checkAtStartup,
    required this.child,
  });
  final GoRouter router;
  final PlayerWindowHost? playerHost;
  final bool checkAtStartup;
  final Widget child;
  @override
  State<UpdateReminderHost> createState() => _UpdateReminderHostState();
}

class _UpdateReminderHostState extends State<UpdateReminderHost>
    with WidgetsBindingObserver {
  UpdateController? _controller;
  AppLifecycleState? _lifecycle;
  bool _scheduled = false;
  bool _startup = false;
  Route<void>? _dialog;
  void Function()? _defer;
  bool get _playing =>
      widget.playerHost?.playbackOccupied == true ||
      widget.router.routeInformationProvider.value.uri.path.startsWith(
        '/play/',
      ) ||
      (widget.router.routerDelegate.currentConfiguration.isNotEmpty &&
          widget.router.state.uri.path.startsWith('/play/'));
  bool get _blocked =>
      _playing ||
      (_lifecycle != null && _lifecycle != AppLifecycleState.resumed);
  @override
  void initState() {
    super.initState();
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    _listen();
  }

  void _listen() {
    widget.router.routerDelegate.addListener(_schedule);
    widget.router.routeInformationProvider.addListener(_schedule);
    widget.playerHost?.addListener(_schedule);
  }

  void _unlisten(UpdateReminderHost value) {
    value.router.routerDelegate.removeListener(_schedule);
    value.router.routeInformationProvider.removeListener(_schedule);
    value.playerHost?.removeListener(_schedule);
  }

  @override
  void didUpdateWidget(UpdateReminderHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _unlisten(oldWidget);
    _listen();
    _schedule();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = UpdateScope.maybeOf(context);
    if (_controller != controller) {
      _controller?.removeListener(_schedule);
      _controller = controller;
      controller?.addListener(_schedule);
    }
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _schedule();
  }

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      if (!_startup && widget.checkAtStartup && _controller != null) {
        _startup = true;
        unawaited(_controller!.checkAtStartup());
      }
      _present();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _present() {
    final navigator = widget.router.routerDelegate.navigatorKey.currentState;
    if (_blocked) {
      if (_dialog?.isActive == true && navigator != null) {
        _defer?.call();
        navigator.removeRoute(_dialog!);
      }
      return;
    }
    final controller = _controller;
    final candidate = controller?.pendingAutomaticRelease;
    if (_dialog != null || navigator == null || candidate == null) return;
    var deferred = false;
    _defer = () => deferred = true;
    final theme = AppUiTheme.of(context);
    final route = CupertinoDialogRoute<void>(
      context: navigator.context,
      barrierDismissible: true,
      builder: (dialogContext) => AppUiTheme(
        data: theme,
        child: UpdateActivityScope(
          playbackOccupied: () => _playing,
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
            },
            child: Actions(
              actions: {
                DismissIntent: CallbackAction<DismissIntent>(
                  onInvoke: (_) {
                    Navigator.of(dialogContext).pop();
                    return null;
                  },
                ),
              },
              child: AppDialog(
                key: const Key('app-update-reminder'),
                title: Text(
                  AppLocalizations.of(dialogContext).updateReminderTitle,
                ),
                content: UpdateCheck(
                  controller: controller,
                  showCheckButton: false,
                  expandNotes: true,
                ),
                actions: [
                  AppButton(
                    key: const Key('app-update-reminder-close'),
                    autofocus: true,
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: Text(AppLocalizations.of(dialogContext).updateLater),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    _dialog = route;
    unawaited(
      navigator.push(route).whenComplete(() {
        if (!mounted) return;
        _dialog = null;
        _defer = null;
        if (!deferred) controller!.acknowledgeAutomaticRelease(candidate);
        _schedule();
      }),
    );
  }

  @override
  void dispose() {
    _defer?.call();
    _controller?.removeListener(_schedule);
    _unlisten(widget);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UpdateActivityScope(
    playbackOccupied: () => _playing,
    child: widget.child,
  );
}
