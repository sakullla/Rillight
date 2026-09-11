import 'package:flutter/widgets.dart';
import 'package:rillight/home/catalog_controller.dart';

class CatalogScope extends InheritedNotifier<CatalogController> {
  const CatalogScope({
    super.key,
    required CatalogController controller,
    required super.child,
  }) : super(notifier: controller);

  static CatalogController of(BuildContext context) {
    final controller = maybeOf(context);
    assert(controller != null, 'CatalogScope not found in context');
    return controller!;
  }

  static CatalogController? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<CatalogScope>()?.notifier;
  }
}
