import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// An engine-local owner. Session tokens are never reused, including retries.
class AndroidPlayer {
  AndroidPlayer({MethodChannel? channel, Stream<dynamic>? events})
    : _channel = channel ?? const MethodChannel('rillight/android_player') {
    _subscription = (events ?? _nativeEvents).listen((event) {
      final data = Map<String, dynamic>.from(event as Map);
      if (data['owner'] == owner && data['sessionId'] == _session) {
        _events.add(data);
      }
    });
  }
  static int _nextOwner = 0;
  static final _nativeEvents = const EventChannel(
    'rillight/android_player/events',
  ).receiveBroadcastStream();
  final String owner =
      'player-${DateTime.now().microsecondsSinceEpoch}-${++_nextOwner}';
  final MethodChannel _channel;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  late final StreamSubscription<dynamic> _subscription;
  Stream<Map<String, dynamic>> get events => _events.stream;
  int _revision = 0;
  String _session = '';
  bool _disposed = false;
  bool _closing = false;
  Future<void>? _disposing;
  String get session => _session;

  Future<Map<String, dynamic>> capabilities() =>
      command('capabilities', const {});

  /// System brightness / volume (ADR-6). These are activity-scoped rather
  /// than bound to a playback session, so they bypass [command] session
  /// gating and stay usable after playback closes. Brightness writes the
  /// window `screenBrightness`; volume drives `AudioManager` STREAM_MUSIC,
  /// alongside the in-app ExoPlayer volume.
  Future<void> setSystemBrightness(double value) async {
    await _channel.invokeMethod<void>('setSystemBrightness', {
      'value': value.clamp(0.0, 1.0),
    });
  }

  Future<double> getSystemBrightness() async {
    return (await _channel.invokeMethod<double>('getSystemBrightness')) ?? -1;
  }

  Future<void> setSystemVolume(double value) async {
    await _channel.invokeMethod<void>('setSystemVolume', {
      'value': value.clamp(0.0, 1.0),
    });
  }

  Future<double> getSystemVolume() async {
    return (await _channel.invokeMethod<double>('getSystemVolume')) ?? 0;
  }

  Future<Map<String, dynamic>> open(Map<String, dynamic> request) async {
    _session = '$owner-${++_revision}';
    return command('open', request, timeout: const Duration(seconds: 25));
  }

  Future<Map<String, dynamic>> command(
    String method,
    Map<String, dynamic> values, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_disposed || (_closing && method != 'dispose')) {
      throw StateError('Android player disposed');
    }
    final expected = _session;
    final Map? response;
    try {
      response = await _channel
          .invokeMethod<Map>(method, {
            ...values,
            'owner': owner,
            'sessionId': expected,
          })
          .timeout(timeout);
    } on PlatformException catch (error) {
      final details = error.details;
      if (expected != _session ||
          details is! Map ||
          details['sessionId'] != expected) {
        throw StateError('Superseded Android playback failure');
      }
      rethrow;
    }
    if (expected != _session || response?['sessionId'] != expected) {
      throw StateError('Superseded Android playback command');
    }
    return Map<String, dynamic>.from(response!);
  }

  Widget buildView({Key? key}) => PlatformViewLink(
    key: key,
    viewType: 'rillight/android_player/view',
    surfaceFactory: (context, controller) => AndroidViewSurface(
      controller: controller as AndroidViewController,
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    ),
    onCreatePlatformView: (params) =>
        PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: 'rillight/android_player/view',
            layoutDirection: TextDirection.ltr,
            creationParams: {'owner': owner},
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () {},
          )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create(),
  );

  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    if (_disposed) return;
    _closing = true;
    try {
      await command('dispose', const {});
    } finally {
      _disposed = true;
      await _subscription.cancel();
      await _events.close();
    }
  }
}
