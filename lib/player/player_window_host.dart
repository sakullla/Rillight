import 'package:flutter/widgets.dart';

import '../aggregation/identity/media_identity.dart';

class PlayerOpenRequest {
  const PlayerOpenRequest({
    required this.itemId,
    this.autoResume = true,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.startPosition,
    this.secondarySubtitleStreamIndex,
    this.source,
    this.work,
    this.libraryId,
    this.startPaused = false,
    this.subtitleOff = false,
    this.maxStreamingBitrate,
    this.accessGeneration,
  });

  final String itemId;
  final bool autoResume;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final Duration? startPosition;

  /// 次字幕(槽位 1)的显式预选;缺省 null 表示次字幕关闭。
  /// 会话导入文件不跨进程传递,只有服务器流索引可表达。
  final int? secondarySubtitleStreamIndex;
  final SourceReference? source;
  final SourceReference? work;
  final String? libraryId;
  final bool startPaused;
  final bool subtitleOff;
  final int? maxStreamingBitrate;
  final int? accessGeneration;

  PlayerOpenRequest withAccessGeneration(int generation) => PlayerOpenRequest(
    itemId: itemId,
    autoResume: autoResume,
    mediaSourceId: mediaSourceId,
    audioStreamIndex: audioStreamIndex,
    subtitleStreamIndex: subtitleStreamIndex,
    startPosition: startPosition,
    secondarySubtitleStreamIndex: secondarySubtitleStreamIndex,
    source: source,
    work: work,
    libraryId: libraryId,
    startPaused: startPaused,
    subtitleOff: subtitleOff,
    maxStreamingBitrate: maxStreamingBitrate,
    accessGeneration: generation,
  );
}

/// 宿主需要主窗口向用户展示的提示。
enum PlayerHostNotice {
  /// 播放进程终止后宿主代发 Stopped 失败,进度未能同步到服务器。
  progressSyncFailed,
}

abstract class PlayerWindowHost extends ChangeNotifier {
  PlayerOpenRequest? get current;
  bool get embedsPlayerInCaller;

  /// Opening a player reserves playback before its process/window is ready.
  /// Pausing never releases this reservation.
  bool get playbackOccupied => current != null;

  /// 宿主产生的、需在主窗口展示的提示;缺省没有。
  Stream<PlayerHostNotice> get notices => const Stream.empty();

  /// A failed manual source transaction remains actionable in the main window.
  String? get switchFailure => null;
  bool get canRestoreOriginal => false;
  Future<void> restoreOriginalSource() async {
    throw StateError('Original source unavailable');
  }

  Future<void> open(PlayerOpenRequest request);
  Future<void> close();

  /// Last-resort process cleanup when graceful shutdown exceeds its deadline.
  Future<void> forceClose() => close();
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
