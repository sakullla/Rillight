import 'dart:async';
import 'dart:io';

/// Address/interface changes are hints to verify transport health, never proof
/// that playback failed. dart:io provides this on Android and all three desktops.
/// Sampling also works without a platform plugin in desktop helper processes.
class NetworkChangeMonitor {
  NetworkChangeMonitor({
    Future<List<String>> Function()? snapshot,
    this.pollInterval = const Duration(seconds: 2),
    this.debounce = const Duration(milliseconds: 750),
  }) : _snapshot = snapshot ?? _interfaces {
    _changes = StreamController<void>.broadcast(
      onListen: _start,
      onCancel: _stop,
    );
  }

  final Future<List<String>> Function() _snapshot;
  final Duration pollInterval;
  final Duration debounce;
  late final StreamController<void> _changes;
  Timer? _poll;
  Timer? _pending;
  String? _previous;
  int _generation = 0;
  bool _sampling = false;
  bool _disposed = false;

  Stream<void> get changes => _changes.stream;

  static Future<List<String>> _interfaces() async {
    final interfaces = await NetworkInterface.list(includeLinkLocal: true);
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          '${interface.index}:${interface.name}:${address.type.name}:${address.address}',
    ];
  }

  void _start() {
    if (_disposed || _poll != null) return;
    unawaited(_sample());
    _poll = Timer.periodic(pollInterval, (_) => unawaited(_sample()));
  }

  Future<void> _sample() async {
    if (_sampling || _disposed) return;
    _sampling = true;
    final generation = _generation;
    try {
      final entries = List<String>.of(await _snapshot());
      if (_disposed || generation != _generation) return;
      entries.sort();
      final current = entries.join('\n');
      final changed = _previous != null && _previous != current;
      _previous = current;
      if (changed) {
        _pending?.cancel();
        _pending = Timer(debounce, () {
          if (!_disposed && generation == _generation) _changes.add(null);
        });
      }
    } on Object {
      // Unavailable interface enumeration is not a transport failure. Preserve
      // the last sample and let actual media requests establish connectivity.
    } finally {
      _sampling = false;
    }
  }

  void _stop() {
    _generation++;
    _poll?.cancel();
    _poll = null;
    _pending?.cancel();
    _pending = null;
    _previous = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    _stop();
    await _changes.close();
  }
}
