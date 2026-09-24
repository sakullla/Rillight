import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// 手机底部导航是贴底还是悬浮。缺省为悬浮。
abstract class PhoneNavStyleStore {
  Future<bool> read();

  Future<void> write(bool floating);
}

class MemoryPhoneNavStyleStore implements PhoneNavStyleStore {
  MemoryPhoneNavStyleStore([this.value = true]);

  bool value;

  @override
  Future<bool> read() async => value;

  @override
  Future<void> write(bool floating) async {
    value = floating;
  }
}

class FilePhoneNavStyleStore implements PhoneNavStyleStore {
  FilePhoneNavStyleStore(this.file);

  final File file;

  @override
  Future<bool> read() async {
    try {
      if (!await file.exists()) {
        return true;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['floating'] is bool) {
        return decoded['floating'] as bool;
      }
    } catch (_) {}
    return true;
  }

  @override
  Future<void> write(bool floating) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({'floating': floating}),
    );
  }
}

Future<PhoneNavStyleStore> openPhoneNavStyleStore() async {
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return MemoryPhoneNavStyleStore();
  }
  try {
    final support = await getApplicationSupportDirectory();
    return FilePhoneNavStyleStore(
      File('${support.path}/rillight/phone_nav.json'),
    );
  } catch (_) {
    return MemoryPhoneNavStyleStore();
  }
}

class PhoneNavStyleController extends ChangeNotifier {
  PhoneNavStyleController({PhoneNavStyleStore? store}) : _store = store;

  PhoneNavStyleStore? _store;
  bool floating = true;
  bool _disposed = false;
  bool _ready = false;

  Future<void> load() async {
    final store = _store ??= await openPhoneNavStyleStore();
    final value = await store.read();
    if (_disposed || _ready) {
      return;
    }
    _ready = true;
    if (floating == value) {
      return;
    }
    floating = value;
    notifyListeners();
  }

  Future<void> setFloating(bool value) async {
    _ready = true;
    if (floating != value) {
      floating = value;
      if (!_disposed) {
        notifyListeners();
      }
    }
    final store = _store ??= await openPhoneNavStyleStore();
    await store.write(value);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class PhoneNavStyle extends InheritedNotifier<PhoneNavStyleController> {
  const PhoneNavStyle({
    super.key,
    required PhoneNavStyleController controller,
    required super.child,
  }) : super(notifier: controller);

  static PhoneNavStyleController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PhoneNavStyle>()
        ?.notifier;
  }

  static bool floatingOf(BuildContext context) =>
      maybeOf(context)?.floating ?? true;
}

/// 包在手机路由外，让首页和「我的」共用同一个开关。
class PhoneNavStyleHost extends StatefulWidget {
  const PhoneNavStyleHost({super.key, required this.child, this.store});

  final Widget child;
  final PhoneNavStyleStore? store;

  @override
  State<PhoneNavStyleHost> createState() => _PhoneNavStyleHostState();
}

class _PhoneNavStyleHostState extends State<PhoneNavStyleHost> {
  late final PhoneNavStyleController _controller = PhoneNavStyleController(
    store: widget.store,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PhoneNavStyle(controller: _controller, child: widget.child);
  }
}
