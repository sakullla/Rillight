import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/file_import.dart';
import 'package:rillight/app/source_route_extra_codec.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/session_subtitle_files.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-subtitle-slots',
  version: '0.1.0',
);

/// 两个内嵌文本字幕轨(2=中文, 3=英文),外加可用的导入路径。
void _withTwoSubtitleStreams(FakeEmbyServer server, {String id = 'movie-up'}) {
  final item = server.items.firstWhere((entry) => entry.id == id);
  item.mediaStreams = const [
    FakeMediaStream(index: 0, type: 'Video', codec: 'h264'),
    FakeMediaStream(
      index: 1,
      type: 'Audio',
      codec: 'aac',
      language: 'jpn',
      displayTitle: 'Japanese',
      isDefault: true,
    ),
    FakeMediaStream(
      index: 2,
      type: 'Subtitle',
      codec: 'ass',
      language: 'chi',
      displayTitle: '中文',
      isDefault: true,
      isTextSubtitleStream: true,
    ),
    FakeMediaStream(
      index: 3,
      type: 'Subtitle',
      codec: 'subrip',
      language: 'eng',
      displayTitle: 'English',
      isTextSubtitleStream: true,
    ),
  ];
}

class _FailSecondaryBackend extends FakeVideoBackend {
  int secondaryAttempts = 0;

  @override
  Future<void> setSubtitleIndex(int index, {int slot = 0}) async {
    if (slot == 1) {
      secondaryAttempts++;
      throw StateError('secondary selection failed');
    }
    await super.setSubtitleIndex(index, slot: slot);
  }

  @override
  Future<bool> setSubtitleUri(
    Uri uri, {
    String? title,
    int? index,
    int slot = 0,
  }) async {
    if (slot == 1) {
      secondaryAttempts++;
      throw StateError('secondary selection failed');
    }
    return super.setSubtitleUri(uri, title: title, index: index, slot: slot);
  }
}

/// 统计外挂注册次数:换源重注册以重新调用 setSubtitleUri 为准。
class _CountingUriBackend extends FakeVideoBackend {
  final List<int> uriSlots = [];

  @override
  Future<bool> setSubtitleUri(
    Uri uri, {
    String? title,
    int? index,
    int slot = 0,
  }) async {
    uriSlots.add(slot);
    return super.setSubtitleUri(uri, title: title, index: index, slot: slot);
  }
}

/// 带显式换行的 SRT:UTF-8 BOM + CRLF + 三行 cue,验证保留原文换行。
Uint8List _multilineSrtBytes() {
  const text =
      '﻿1\r\n'
      '00:00:01,000 --> 00:00:04,000\r\n'
      '第一行显式分行\r\n第二行\r\n第三行\r\n\r\n'
      '2\r\n'
      '00:00:05,000 --> 00:00:08,000\r\n'
      'Another explicit\r\nline pair\r\n';
  return Uint8List.fromList(utf8.encode(text));
}

void main() {
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;
  late FakeVideoBackend backend;
  late PlayerWindow window;

  setUp(() {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
    backend = FakeVideoBackend();
    window = PlayerWindow();
  });

  Future<PlayerController> startController({
    String itemId = 'movie-up',
    int? preferredSecondary,
    AppFilePicker? filePicker,
  }) async {
    final client = EmbyClient(device: _device, dio: dioForFakeEmby(adapter));
    final auth = AuthController(
      client: client,
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    expect(auth.isLoggedIn, isTrue);
    final controller = PlayerController(
      client: client,
      itemId: itemId,
      backend: backend,
      window: window,
      progressInterval: const Duration(seconds: 10),
      settingsStore: MemoryPlayerSettingsStore(),
      snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      preferredSecondarySubtitleStreamIndex: preferredSecondary,
      subtitleFilePicker: filePicker,
    );
    await controller.start();
    expect(controller.loading, isFalse);
    expect(controller.resolved, isNotNull);
    return controller;
  }

  test('launch payload and route extra represent the secondary slot', () {
    final launch = PlayerWindowLaunch.fromJson({
      'itemId': 'movie-up',
      'baseUrl': 'https://emby.example.test',
      'accessToken': 'token',
      'userId': 'u',
      'subtitleStreamIndex': 2,
      'secondarySubtitleStreamIndex': 3,
    });
    expect(launch.request.secondarySubtitleStreamIndex, 3);
    expect(launch.toJson()['secondarySubtitleStreamIndex'], 3);

    const codec = SourceRouteExtraCodec();
    final encoded = codec.encode(
      const PlayerOpenRequest(
        itemId: 'movie-up',
        secondarySubtitleStreamIndex: 3,
      ),
    );
    final restored = codec.decode(encoded) as PlayerOpenRequest;
    expect(restored.secondarySubtitleStreamIndex, 3);
    expect(
      (codec.decode(codec.encode(const PlayerOpenRequest(itemId: 'x')))
              as PlayerOpenRequest)
          .secondarySubtitleStreamIndex,
      isNull,
      reason: '缺省表示次字幕关闭',
    );
  });

  test('two slots select and turn off independently', () async {
    _withTwoSubtitleStreams(server);
    final controller = await startController();
    addTearDown(controller.dispose);
    expect(controller.subtitleStreamIndex, 2, reason: '默认主字幕仍是服务器默认轨');
    expect(controller.secondarySubtitleStreamIndex, isNull);

    await controller.setSecondarySubtitle(3);
    expect(controller.secondarySubtitleStreamIndex, 3);
    expect(backend.secondarySubtitleIndex, 3);
    expect(controller.subtitleStreamIndex, 2, reason: '次字幕选择不影响主字幕');
    expect(backend.subtitleIndex, 2);

    await controller.setSubtitle(null);
    expect(controller.subtitleStreamIndex, isNull);
    expect(backend.subtitleOff, isTrue);
    expect(controller.secondarySubtitleStreamIndex, 3, reason: '主字幕关闭不影响次字幕');
    expect(backend.secondarySubtitleIndex, 3);

    await controller.setSecondarySubtitle(null);
    expect(controller.secondarySubtitleStreamIndex, isNull);
    expect(controller.secondarySubtitleFileId, isNull);
    expect(backend.secondarySubtitleIndex, isNull);
  });

  test('the same server stream cannot occupy both slots', () async {
    _withTwoSubtitleStreams(server);
    final controller = await startController();
    addTearDown(controller.dispose);
    await controller.setSecondarySubtitle(3);
    expect(controller.secondarySubtitleStreamIndex, 3);

    await controller.setSubtitle(3);
    expect(controller.subtitleStreamIndex, 2, reason: '主槽选择被拒绝,不改变现状');
    expect(controller.subtitleSelectionNotice, 'occupied');
    expect(backend.subtitleIndex, 2);

    controller.clearSubtitleSelectionNotice();
    expect(controller.subtitleSelectionNotice, isNull);

    await controller.setSecondarySubtitle(2);
    expect(controller.secondarySubtitleStreamIndex, 3, reason: '次槽选择被拒绝,保持原选择');
    expect(controller.subtitleSelectionNotice, 'occupied');
  });

  test(
    'secondary selection failure rolls back without touching primary',
    () async {
      backend = _FailSecondaryBackend();
      _withTwoSubtitleStreams(server);
      final controller = await startController();
      addTearDown(controller.dispose);
      expect(controller.subtitleStreamIndex, 2);
      final position = controller.position;

      await controller.setSecondarySubtitle(3);
      expect(
        (backend as _FailSecondaryBackend).secondaryAttempts,
        greaterThanOrEqualTo(1),
      );
      expect(controller.secondarySubtitleStreamIndex, isNull);
      expect(controller.trackFailure, isNotNull);
      expect(controller.subtitleStreamIndex, 2, reason: '另一槽位不受失败影响');
      expect(controller.position, position, reason: '播放位置不受失败影响');
      expect(controller.isPlaying, backend.isPlaying);
    },
  );

  test('preferred secondary preselection applies once at startup', () async {
    _withTwoSubtitleStreams(server);
    final controller = await startController(preferredSecondary: 3);
    addTearDown(controller.dispose);
    expect(controller.secondarySubtitleStreamIndex, 3);
    expect(backend.secondarySubtitleIndex, 3);
    expect(controller.subtitleStreamIndex, 2);
  });

  test('import validates strictly and preserves original bytes', () async {
    _withTwoSubtitleStreams(server);
    final controller = await startController();
    addTearDown(controller.dispose);
    final bytes = _multilineSrtBytes();

    final outcome = await controller.importSubtitleBytes(
      fileName: 'multiline.srt',
      bytes: bytes,
    );
    expect(outcome, SubtitleImportOutcome.added);
    expect(controller.sessionSubtitleFiles, hasLength(1));
    final file = controller.sessionSubtitleFiles.single;
    expect(file.format, SubtitleFileFormat.srt);
    expect(file.label, 'multiline.srt');
    final stored = await file.file.readAsBytes();
    expect(stored, bytes, reason: '会话副本逐字节保留 BOM 与 CRLF 换行');
    expect(controller.subtitleImportNotice, isNull);

    final duplicate = await controller.importSubtitleBytes(
      fileName: 'copy.srt',
      bytes: bytes,
    );
    expect(duplicate, SubtitleImportOutcome.duplicate);
    expect(controller.sessionSubtitleFiles, hasLength(1), reason: '重复内容不增加候选');
    expect(controller.subtitleImportNotice, SubtitleImportOutcome.duplicate);

    final invalidUtf8 = Uint8List.fromList([
      0x31,
      0x0A,
      0x30,
      0x30,
      0x3A,
      0x30,
      0x30,
      0x3A,
      0x30,
      0x30,
      0x2C,
      0x30,
      0x30,
      0x30,
      0x20,
      0x2D,
      0x2D,
      0x3E,
      0x20,
      0x30,
      0x30,
      0x3A,
      0x30,
      0x30,
      0x3A,
      0x30,
      0x30,
      0x2C,
      0x30,
      0x30,
      0x30,
      0x0A,
      0xFF,
      0xFE,
      0x0A,
    ]);
    expect(
      await controller.importSubtitleBytes(
        fileName: 'broken.srt',
        bytes: invalidUtf8,
      ),
      SubtitleImportOutcome.invalidFormat,
    );
    expect(
      await controller.importSubtitleBytes(
        fileName: 'page.html',
        bytes: Uint8List.fromList(
          '<!doctype html><html><body>x</body></html>'.codeUnits,
        ),
      ),
      SubtitleImportOutcome.invalidFormat,
    );
    expect(controller.sessionSubtitleFiles, hasLength(1), reason: '无效文件不增加候选');
  });

  test('imported files fill either slot but never both', () async {
    _withTwoSubtitleStreams(server);
    final controller = await startController();
    addTearDown(controller.dispose);
    final srt = _multilineSrtBytes();
    await controller.importSubtitleBytes(fileName: 'a.srt', bytes: srt);
    const vttHeader = 'WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nLine one\n';
    await controller.importSubtitleBytes(
      fileName: 'b.vtt',
      bytes: Uint8List.fromList(vttHeader.codeUnits),
    );
    expect(controller.sessionSubtitleFiles, hasLength(2));
    final first = controller.sessionSubtitleFiles.first;
    final second = controller.sessionSubtitleFiles.last;

    await controller.setSubtitleFromFile(first.id);
    expect(controller.primarySubtitleFileId, first.id);
    expect(controller.subtitleStreamIndex, isNull);
    expect(backend.subtitleUri?.scheme, 'file');
    expect(backend.subtitleIndex, isNull, reason: '主槽由文件占用,不再有服务器轨');

    await controller.setSecondarySubtitleFromFile(first.id);
    expect(controller.secondarySubtitleFileId, isNull, reason: '同一文件不可重复占用两槽');
    expect(controller.subtitleSelectionNotice, 'occupied');

    await controller.setSecondarySubtitleFromFile(second.id);
    expect(controller.secondarySubtitleFileId, second.id);
    expect(backend.secondarySubtitleUri?.scheme, 'file');

    // 关闭主字幕后文件候选仍在,可再次选择。
    await controller.setSubtitle(null);
    expect(controller.primarySubtitleFileId, isNull);
    expect(controller.secondarySubtitleFileId, second.id);
    await controller.setSubtitleFromFile(first.id);
    expect(controller.primarySubtitleFileId, first.id);
  });

  test('import outcome surfaces picker unavailability', () async {
    _withTwoSubtitleStreams(server);
    final controller = await startController(filePicker: _UnavailablePicker());
    addTearDown(controller.dispose);
    final outcome = await controller.importSubtitleFile();
    expect(outcome, SubtitleImportOutcome.pickerUnavailable);
    expect(
      controller.subtitleImportNotice,
      SubtitleImportOutcome.pickerUnavailable,
    );
    expect(controller.sessionSubtitleFiles, isEmpty);
  });

  test('import through the injectable picker reads bounded bytes', () async {
    _withTwoSubtitleStreams(server);
    final controller = await startController(
      filePicker: _FakePicker(_multilineSrtBytes(), 'picked.srt'),
    );
    addTearDown(controller.dispose);
    expect(await controller.importSubtitleFile(), SubtitleImportOutcome.added);
    expect(controller.sessionSubtitleFiles.single.label, 'picked.srt');
  });

  test('changing episodes clears session files and secondary slot', () async {
    _withTwoSubtitleStreams(server);
    _withTwoSubtitleStreams(server, id: 'episode-friends-s1e1');
    final controller = await startController();
    addTearDown(controller.dispose);
    await controller.importSubtitleBytes(
      fileName: 'a.srt',
      bytes: _multilineSrtBytes(),
    );
    await controller.setSecondarySubtitleFromFile(
      controller.sessionSubtitleFiles.single.id,
    );
    expect(controller.secondarySubtitleFileId, isNotNull);

    await controller.playEpisode(
      EmbyItem.fromJson({
        'Id': 'episode-friends-s1e1',
        'Type': 'Episode',
        'Name': 'episode-friends-s1e1',
      }),
    );
    expect(controller.loading, isFalse);
    expect(controller.sessionSubtitleFiles, isEmpty, reason: '换媒体清理关联');
    expect(controller.secondarySubtitleFileId, isNull);
    expect(controller.secondarySubtitleStreamIndex, isNull);
  });

  test('same-session source switch re-registers the imported file', () async {
    backend = _CountingUriBackend();
    _withTwoSubtitleStreams(server);
    final movie = server.items.firstWhere((entry) => entry.id == 'movie-up');
    movie.extraSources = const [
      FakeMediaSource(id: 'version-b', name: 'Version B', container: 'mkv'),
    ];
    final controller = await startController();
    addTearDown(controller.dispose);
    await controller.importSubtitleBytes(
      fileName: 'a.srt',
      bytes: _multilineSrtBytes(),
    );
    await controller.setSubtitleFromFile(
      controller.sessionSubtitleFiles.single.id,
    );
    expect(backend.subtitleUri, isNotNull);
    final fileBefore = controller.primarySubtitleFileId;
    final registered = (backend as _CountingUriBackend).uriSlots.length;
    expect(registered, 1);

    await controller.switchMediaVersion('version-b');
    expect(controller.loading, isFalse);
    expect(controller.primarySubtitleFileId, fileBefore, reason: '同会话换源保留槽位');
    expect(backend.subtitleUri, isNotNull);
    expect(
      (backend as _CountingUriBackend).uriSlots.length,
      registered + 1,
      reason: '换源后重新注册外挂文件',
    );
  });
}

class _UnavailablePicker implements AppFilePicker {
  @override
  Future<PickedAppFile?> pickFile({
    required String dialogTitle,
    required List<String> allowedExtensions,
  }) async {
    throw const AppFilePickerUnavailableException('no-provider');
  }
}

class _FakePicker implements AppFilePicker {
  _FakePicker(this.bytes, this.fileName);

  final Uint8List bytes;
  final String fileName;
  int? observedLimit;

  @override
  Future<PickedAppFile?> pickFile({
    required String dialogTitle,
    required List<String> allowedExtensions,
  }) async {
    return PickedAppFile(
      fileName: fileName,
      length: bytes.length,
      read: (limit) async {
        observedLimit = limit;
        if (bytes.length > limit) {
          throw AppFileTooLargeException(bytes.length, limit);
        }
        return bytes;
      },
    );
  }
}
