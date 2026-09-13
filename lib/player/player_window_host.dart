import 'package:flutter/widgets.dart';

class PlayerOpenRequest {
  const PlayerOpenRequest({
    required this.itemId,
    this.autoResume = true,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.startTimeTicks,
  });

  final String itemId;
  final bool autoResume;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final int? startTimeTicks;
}

abstract class PlayerWindowHost extends ChangeNotifier {
  PlayerOpenRequest? get current;
  bool get embedsPlayerInCaller;

  Future<void> open(PlayerOpenRequest request);
  Future<void> close();
}

class OverlayPlayerWindowHost extends PlayerWindowHost {
  PlayerOpenRequest? _current;

  @override
  PlayerOpenRequest? get current => _current;

  @override
  bool get embedsPlayerInCaller => true;

  @override
  Future<void> open(PlayerOpenRequest request) async {
    _current = request;
    notifyListeners();
  }

  @override
  Future<void> close() async {
    if (_current == null) {
      return;
    }
    _current = null;
    notifyListeners();
  }
}

class PlayerWindowScope extends InheritedNotifier<PlayerWindowHost> {
  const PlayerWindowScope({
    super.key,
    required PlayerWindowHost host,
    required super.child,
  }) : super(notifier: host);

  static PlayerWindowHost of(BuildContext context) {
    final host = maybeOf(context);
    assert(host != null, 'PlayerWindowScope not found in context');
    return host!;
  }

  static PlayerWindowHost? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PlayerWindowScope>()
        ?.notifier;
  }
}
