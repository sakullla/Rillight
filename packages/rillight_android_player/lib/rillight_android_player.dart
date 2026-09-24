import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Whole frame with only the black bars the aspect ratio needs.
/// Cropped frame that removes those bars.
enum AndroidVideoScale { fit, fill }

/// Ancestor for the phone player. Absent readers stay on [AndroidVideoScale.fit].
class AndroidVideoScaleScope extends InheritedWidget {
  const AndroidVideoScaleScope({
    super.key,
    required this.scale,
    required super.child,
  });

  final AndroidVideoScale scale;

  static AndroidVideoScale maybeOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<AndroidVideoScaleScope>()
            ?.scale ??
        AndroidVideoScale.fit;
  }

  @override
  bool updateShouldNotify(AndroidVideoScaleScope oldWidget) =>
      scale != oldWidget.scale;
}

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

  /// Asks Media3 for fit (letterbox) or fill (crop). Safe when the view
  /// does not exist yet: the owner keeps the mode for the next `PlayerView`.
  Future<void> setVideoScale(AndroidVideoScale scale) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('setVideoScale', {
        'owner': owner,
        'sessionId': _session,
        'mode': scale.name,
      });
    } on PlatformException {
      // Widget tests and non-Android embeds have no Media3 view.
    }
  }

  Widget buildView({Key? key}) => _ScaleBoundPlayerView(key: key, player: this);

  Widget _platformView() => PlatformViewLink(
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

class _ScaleBoundPlayerView extends StatefulWidget {
  const _ScaleBoundPlayerView({super.key, required this.player});

  final AndroidPlayer player;

  @override
  State<_ScaleBoundPlayerView> createState() => _ScaleBoundPlayerViewState();
}

class _ScaleBoundPlayerViewState extends State<_ScaleBoundPlayerView> {
  AndroidVideoScale? _applied;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scale = AndroidVideoScaleScope.maybeOf(context);
    if (_applied == scale) return;
    _applied = scale;
    unawaited(widget.player.setVideoScale(scale));
  }

  @override
  Widget build(BuildContext context) => widget.player._platformView();
}
