import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/android_video_backend.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight_android_player/rillight_android_player.dart';

import '../emby/fake_emby_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('android-transcode-subtitle-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _SubtitleClient client;
  late AndroidPlayer player;
  late AndroidVideoBackend backend;
  late PlayerController controller;
  late StreamController<dynamic> events;
  final calls = <MethodCall>[];
  Completer<void>? subtitleGate;
  var rejectSubtitle = false;
  int? nativeSubtitle;

  PlayerController makeController(VideoBackend video) => PlayerController(
    client: client,
    itemId: 'movie-up',
    backend: video,
    window: PlayerWindow(),
    settingsStore: MemoryPlayerSettingsStore(),
    snapshotStore: MemoryPlaybackSessionSnapshotStore(),
  );
  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 100 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(condition(), isTrue);
  }

  setUp(() async {
    calls.clear();
    subtitleGate = null;
    rejectSubtitle = false;
    nativeSubtitle = null;
    final server = FakeEmbyServer();
    client = _SubtitleClient(server);
    final auth = await client.authenticateByName(
      baseUrl: server.baseUrl,
      username: 'alice',
      password: 'correct-horse',
      serverId: server.serverId,
    );
    client.attachSession(
      baseUrl: server.baseUrl,
      accessToken: auth.accessToken,
      userId: auth.user.id,
    );
    events = StreamController<dynamic>.broadcast();
    player = AndroidPlayer(channel: channel, events: events.stream);
    backend = AndroidVideoBackend(player: player);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments as Map;
      if (call.method == 'open') nativeSubtitle = null;
      if (call.method == 'subtitleUri' || call.method == 'subtitle') {
        await subtitleGate?.future;
        if (rejectSubtitle) {
          throw PlatformException(
            code: 'track',
            message: 'Native subtitle rejected',
            details: {'sessionId': args['sessionId']},
          );
        }
        nativeSubtitle = call.method == 'subtitle'
            ? args['index'] as int
            : null;
      }
      if (call.method == 'subtitleOff') nativeSubtitle = null;
      return {
        'sessionId': args['sessionId'],
        'h264': true,
        'aac': true,
        'subtitleIndex': nativeSubtitle,
      };
    });
    controller = makeController(backend);
  });
  tearDown(() async {
    if (subtitleGate != null && !subtitleGate!.isCompleted) {
      subtitleGate!.complete();
    }
    await controller.disposeAsync();
    controller.dispose();
    await backend.dispose();
    await events.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  for (final change in [
    'off',
    'another track',
    'same track',
    'media',
    'close',
  ]) {
    test('late External download cannot undo $change', () async {
      final download = Completer<List<int>>();
      addTearDown(() {
        if (!download.isCompleted) {
          download.complete(utf8.encode('WEBVTT\n\nold'));
        }
      });
      client.downloadOverride = (uri) => client.downloads.length == 1
          ? download.future
          : Future.value(
              utf8.encode('WEBVTT\n\n00:00.000 --> 00:10.000\nCURRENT'),
            );
      final starting = controller.start();
      await until(() => client.downloads.isNotEmpty);
      expect(controller.loading, isFalse);
      switch (change) {
        case 'off':
          await controller.setSubtitle(null);
        case 'another track':
          await controller.setSubtitle(28);
        case 'same track':
          await controller.setSubtitle(27);
        case 'media':
          controller.itemId = 'movie-inception';
          await controller.start();
        case 'close':
          await controller.disposeAsync();
      }
      final before = calls.where((c) => c.method == 'subtitleUri').toList();
      final currentFile = before.isEmpty
          ? null
          : File.fromUri(
              Uri.parse((before.last.arguments as Map)['url'] as String),
            );
      download.complete(
        utf8.encode('WEBVTT\n\n00:00.000 --> 00:10.000\nSTALE'),
      );
      await starting;
      expect(
        calls.where((c) => c.method == 'subtitleUri').length,
        before.length,
        reason: 'Cancelled download must never send a native command',
      );
      if (currentFile != null) {
        expect(await currentFile.exists(), isTrue);
        expect(await currentFile.readAsString(), contains('CURRENT'));
        final files = await currentFile.parent
            .list()
            .where((f) => f is File)
            .toList();
        expect(
          files,
          hasLength(1),
          reason: 'Only the current selection owns a cache file',
        );
      }
      if (change != 'close') {
        expect(
          controller.subtitleStreamIndex,
          change == 'off'
              ? null
              : change == 'another track'
              ? 28
              : 27,
        );
        expect(controller.trackFailure, isNull);
      }
    });
  }

  test(
    'manual External download is cancelled before native selection',
    () async {
      await controller.start();
      final download = Completer<List<int>>();
      client.downloadOverride = (_) => download.future;
      final changing = controller.setSubtitle(28);
      await until(() => client.downloads.length == 2);
      await controller.setSubtitle(null);
      final before = calls.where((c) => c.method == 'subtitleUri').length;
      download.complete(
        utf8.encode('WEBVTT\n\n00:00.000 --> 00:10.000\nSTALE'),
      );
      await changing;
      expect(calls.where((c) => c.method == 'subtitleUri').length, before);
      expect(controller.subtitleStreamIndex, isNull);
      expect(controller.trackFailure, isNull);
    },
  );

  test('late native completion cleans only its candidate file', () async {
    final gate = subtitleGate = Completer<void>();
    final starting = controller.start();
    await until(() => calls.any((c) => c.method == 'subtitleUri'));
    File selectedFile() => File.fromUri(
      Uri.parse(
        (calls.lastWhere((c) => c.method == 'subtitleUri').arguments
                as Map)['url']
            as String,
      ),
    );
    final oldFile = selectedFile();
    subtitleGate = null;
    await controller.setSubtitle(28);
    final currentFile = selectedFile();
    gate.complete();
    await starting;
    expect(currentFile.path, isNot(oldFile.path));
    expect(await currentFile.exists(), isTrue);
    expect(await oldFile.exists(), isFalse);
    expect(await currentFile.parent.list().toList(), hasLength(1));
    expect(controller.subtitleStreamIndex, 28);
  });

  test(
    'selection cancelled during file write cannot activate or delete its successor',
    () async {
      final io = _SubtitleWriteGate();
      await IOOverrides.runWithIOOverrides(() async {
        final starting = controller.start();
        await io.written.future;
        await controller.setSubtitle(28);
        final native = calls.where((c) => c.method == 'subtitleUri').single;
        final currentFile = File.fromUri(
          Uri.parse((native.arguments as Map)['url'] as String),
        );
        io.release.complete();
        await starting;
        expect(calls.where((c) => c.method == 'subtitleUri'), hasLength(1));
        expect(controller.subtitleStreamIndex, 28);
        expect(await currentFile.exists(), isTrue);
        expect(await io.candidate!.exists(), isFalse);
        expect(await currentFile.parent.list().toList(), hasLength(1));
      }, io);
    },
  );

  test(
    'HLS External subtitle stays unselected until native confirmation',
    () async {
      subtitleGate = Completer<void>();
      final starting = controller.start();
      await until(() => calls.any((c) => c.method == 'subtitleUri'));
      expect(controller.isTranscode, isTrue);
      expect(controller.loading, isFalse);
      expect(controller.subtitleStreamIndex, isNull);
      expect(
        client.reports.every((r) => r.subtitleStreamIndex == null),
        isTrue,
      );
      expect(client.downloads.single.path, '/subtitles/main.vtt');
      expect(
        client.downloads.single.queryParameters['api_key'],
        client.accessToken,
      );
      subtitleGate!.complete();
      await starting;
      expect(controller.subtitleStreamIndex, 27);
      expect(controller.trackFailure, isNull);
      await controller.setSubtitle(null);
      expect(controller.subtitleStreamIndex, isNull);
      expect(calls.where((c) => c.method == 'open'), hasLength(1));
    },
  );

  for (final failure in ['download', 'native']) {
    test(
      'HLS External $failure failure never reports or commits subtitle success',
      () async {
        client.failDownload = failure == 'download';
        rejectSubtitle = failure == 'native';
        await controller.start();
        expect(controller.error, isNull);
        expect(controller.trackFailure, isNotNull);
        expect(controller.subtitleStreamIndex, isNull);
        expect(
          client.reports.every((r) => r.subtitleStreamIndex == null),
          isTrue,
        );
        expect(calls.where((c) => c.method == 'open'), hasLength(1));
        client.failDownload = false;
        rejectSubtitle = false;
        await controller.setSubtitle(27);
        expect(controller.subtitleStreamIndex, 27);
        expect(controller.trackFailure, isNull);
        expect(client.reports.last.subtitleStreamIndex, 27);
      },
    );
  }

  test(
    'failed HLS external switch preserves confirmed subtitle without reopening video',
    () async {
      await controller.start();
      expect(controller.subtitleStreamIndex, 27);
      rejectSubtitle = true;
      await controller.setSubtitle(28);
      expect(controller.subtitleStreamIndex, 27);
      expect(controller.trackFailure, isNotNull);
      expect(client.reports.any((r) => r.subtitleStreamIndex == 28), isFalse);
      expect(calls.where((c) => c.method == 'open'), hasLength(1));
    },
  );

  test(
    'HLS manifest subtitle is mapped and confirmed instead of downloaded or assumed burned',
    () async {
      client.delivery = 'Hls';
      await controller.start();
      expect(client.downloads, isEmpty);
      expect(
        calls.where((c) => c.method == 'subtitle').single.arguments,
        containsPair('index', 27),
      );
      final streams =
          (calls.firstWhere((c) => c.method == 'open').arguments
                  as Map)['streams']
              as List;
      expect(streams, hasLength(1));
      expect(streams.single, containsPair('index', 27));
      expect(streams.single, containsPair('external', false));
      expect(controller.subtitleStreamIndex, 27);
    },
  );

  test(
    'older server without DeliveryMethod still honors Android External profile',
    () async {
      client.delivery = null;
      await controller.start();
      expect(calls.where((c) => c.method == 'subtitleUri'), hasLength(1));
      expect(controller.subtitleStreamIndex, 27);
    },
  );

  test('explicit Encode keeps Android server burn-in behavior', () async {
    client.delivery = 'Encode';
    await controller.start();
    expect(client.downloads, isEmpty);
    expect(
      calls.where((c) => c.method == 'subtitleUri' || c.method == 'subtitle'),
      isEmpty,
    );
    expect(controller.subtitleStreamIndex, 27);
  });

  test('desktop transcode keeps existing server burn-in behavior', () async {
    await controller.disposeAsync();
    controller.dispose();
    final desktop = FakeVideoBackend();
    controller = makeController(desktop);
    await controller.start();
    expect(client.downloads, isEmpty);
    expect(desktop.subtitleUri, isNull);
    expect(controller.subtitleStreamIndex, 27);
    await controller.setSubtitle(28);
    expect(desktop.openCount, 2);
  });
}

final class _SubtitleWriteGate extends IOOverrides {
  final written = Completer<void>();
  final release = Completer<void>();
  File? candidate;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    if (candidate == null && path.contains('rillight-subtitles-')) {
      candidate = file;
      return _GatedSubtitleFile(file, this);
    }
    return file;
  }
}

class _GatedSubtitleFile implements File {
  _GatedSubtitleFile(this.file, this.gate);
  final File file;
  final _SubtitleWriteGate gate;
  @override
  String get path => file.path;
  @override
  Uri get uri => file.uri;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    await file.writeAsBytes(bytes, mode: mode, flush: flush);
    gate.written.complete();
    await gate.release.future;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SubtitleClient extends EmbyClient {
  _SubtitleClient(FakeEmbyServer server)
    : super(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'test',
          version: '1',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      );
  String? delivery = 'External';
  bool failDownload = false;
  Future<List<int>> Function(Uri)? downloadOverride;
  final downloads = <Uri>[];
  final reports = <PlaybackReport>[];
  @override
  Future<PlaybackInfo> getPlaybackInfo({
    required String itemId,
    int? maxStreamingBitrate,
    int? startTimeTicks,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    String? mediaSourceId,
    Map<String, dynamic>? deviceProfile,
    bool forceTranscode = false,
  }) async => PlaybackInfo.fromJson({
    'PlaySessionId': 'hls-session',
    'MediaSources': [
      {
        'Id': 'hls-source',
        'SupportsTranscoding': true,
        'TranscodingUrl': '/videos/movie-up/master.m3u8',
        'DefaultSubtitleStreamIndex': 27,
        'MediaStreams': [
          {
            'Index': 27,
            'Type': 'Subtitle',
            'Codec': 'vtt',
            'IsExternal': true,
            'DeliveryMethod': delivery,
            'DeliveryUrl': '/subtitles/main.vtt',
          },
          {
            'Index': 28,
            'Type': 'Subtitle',
            'Codec': 'srt',
            'IsExternal': true,
            'DeliveryMethod': 'External',
            'DeliveryUrl': '/subtitles/other.srt',
          },
        ],
      },
    ],
  });
  @override
  Future<List<int>> readAuthorizedBytes(
    Uri uri, {
    Duration receiveTimeout = const Duration(seconds: 60),
    int attempts = 3,
  }) async {
    downloads.add(uri);
    if (downloadOverride != null) return downloadOverride!(uri);
    if (failDownload) throw StateError('Subtitle download failed');
    return utf8.encode('WEBVTT\n\n00:00.000 --> 00:10.000\nHLS subtitle\n');
  }

  @override
  Future<void> reportPlaying(PlaybackReport report) async {
    reports.add(report);
  }

  @override
  Future<void> reportProgress(PlaybackReport report) async {
    reports.add(report);
  }

  @override
  Future<void> reportStopped(PlaybackReport report) async {
    reports.add(report);
  }
}
