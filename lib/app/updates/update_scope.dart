import '../ui/ui.dart';
import 'update_controller.dart';
import 'update_platform.dart';

class UpdateScope extends InheritedNotifier<UpdateController> {
  const UpdateScope({
    super.key,
    required UpdateController? controller,
    required super.child,
  }) : super(notifier: controller);

  static UpdateController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateScope>()?.notifier;
}

/// Only production entry points enable creation. Tests can inject a controller
/// without giving an ordinary RillightApp access to the network or installers.
class UpdateScopeHost extends StatefulWidget {
  const UpdateScopeHost({
    super.key,
    required this.enabled,
    this.controller,
    required this.child,
  });
  final bool enabled;
  final UpdateController? controller;
  final Widget child;
  @override
  State<UpdateScopeHost> createState() => _UpdateScopeHostState();
}

class _UpdateScopeHostState extends State<UpdateScopeHost> {
  UpdateController? _owned;
  @override
  void initState() {
    super.initState();
    if (widget.enabled && widget.controller == null) {
      _owned = UpdateController(platform: SystemUpdatePlatform());
    }
  }

  @override
  void didUpdateWidget(UpdateScopeHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && widget.controller == null && _owned == null) {
      _owned = UpdateController(platform: SystemUpdatePlatform());
    }
  }

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      UpdateScope(controller: widget.controller ?? _owned, child: widget.child);
}
