import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../product.dart';
import '../../player/player_settings.dart';
import 'update_download.dart';
import 'update_platform_contract.dart';
import 'update_service.dart';

enum UpdateCheckPhase { idle, checking, available, current, failed }

enum UpdateCheckFailure {
  network,
  timeout,
  rateLimited,
  noRelease,
  invalidResponse,
}

enum UpdateDownloadPhase {
  idle,
  downloading,
  verifying,
  ready,
  cancelled,
  failed,
}

class UpdateDownloadState {
  const UpdateDownloadState({
    this.phase = UpdateDownloadPhase.idle,
    this.release,
    this.asset,
    this.received = 0,
    this.total,
    this.verified,
    this.failure,
    this.failedPhase,
  });
  final UpdateDownloadPhase phase;
  final AppRelease? release;
  final ReleaseAsset? asset;
  final int received;
  final int? total;
  final VerifiedUpdate? verified;
  final UpdateDownloadFailure? failure;

  /// Retains the operation that failed after [phase] becomes failed.
  final UpdateDownloadPhase? failedPhase;
  bool get busy =>
      phase == UpdateDownloadPhase.downloading ||
      phase == UpdateDownloadPhase.verifying;
  double? get fraction =>
      total != null && total! > 0 ? (received / total!).clamp(0, 1) : null;
}

/// Owned once by the main application, never by an individual settings page.
class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.platform,
    UpdateService? service,
    UpdateDownloader? downloader,
    PlayerSettingsStore? settingsStore,
    this.openSettingsStore,
    this.currentVersion = kAppVersion,
    this.autoReminderEnabled = true,
    String? ignoredVersion,
  }) : _service = service ?? UpdateService(),
       _downloader = downloader ?? UpdateDownloader(),
       _settingsStore = settingsStore,
       ignoredVersion = _normalizeVersion(ignoredVersion) {
    if (settingsStore != null) {
      _preferencesLoad = _loadPreferences(Future.value(settingsStore));
    }
  }
  static const _ioTimeout = Duration(seconds: 2);

  final UpdatePlatform platform;
  final UpdateService _service;
  final UpdateDownloader _downloader;
  final PlayerSettingsStore? _settingsStore;
  final Future<PlayerSettingsStore> Function()? openSettingsStore;
  final String currentVersion;

  UpdateCheckPhase checkPhase = UpdateCheckPhase.idle;
  UpdateCheckFailure? checkFailure;
  AppRelease? release;
  UpdateAssetSelection? selection;
  UpdateCapabilities? capabilities;
  bool manualCheck = false;
  bool autoReminderEnabled;
  String? ignoredVersion;
  UpdateDownloadState download = const UpdateDownloadState();
  UpdateActionResult? releaseAction;
  UpdateActionResult? installAction;
  UpdateActionResult? permissionAction;
  bool openingRelease = false;
  bool installing = false;
  bool requestingPermission = false;

  Future<void>? _checking;
  Future<PlayerSettingsStore>? _openedStore;
  Future<void>? _preferencesLoad;
  bool _preferencesLoaded = false;
  int _preferenceRevision = 0;
  CancelToken? _cancelToken;
  int _downloadGeneration = 0;
  bool _disposed = false;
  bool _startupChecked = false;
  bool _autoRequested = false;
  final Set<String> _shownVersions = {};
  AppRelease? _automaticRelease;

  /// Host additionally arbitrates playback, lifecycle, routes and navigator state.
  AppRelease? get pendingAutomaticRelease => _automaticRelease;

  static String _versionKey(AppRelease candidate) =>
      candidate.version.toString().split('+').first;

  static String? _normalizeVersion(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final clean = trimmed.startsWith('v') || trimmed.startsWith('V')
        ? trimmed.substring(1)
        : trimmed;
    final key = clean.split('+').first.trim();
    return key.isEmpty ? null : key;
  }

  bool isReleaseIgnored(AppRelease? candidate) =>
      candidate != null &&
      ignoredVersion != null &&
      ignoredVersion == _versionKey(candidate);

  void acknowledgeAutomaticRelease(AppRelease candidate) {
    _shownVersions.add(_versionKey(candidate));
    if (_automaticRelease == candidate) _automaticRelease = null;
    _notify();
  }

  Future<void> ignoreRelease([AppRelease? candidate]) async {
    final target = candidate ?? _automaticRelease ?? release;
    if (_disposed || target == null) return;
    _preferenceRevision++;
    final key = _versionKey(target);
    ignoredVersion = key;
    _shownVersions.add(key);
    if (_automaticRelease == target) _automaticRelease = null;
    _notify();
    await _writePreferences(PlayerSettings(ignoredUpdateVersion: key));
  }

  Future<void> unignoreRelease() async {
    if (_disposed || ignoredVersion == null) return;
    _preferenceRevision++;
    _shownVersions.remove(ignoredVersion);
    ignoredVersion = null;
    _notify();
    await _writePreferences(const PlayerSettings(ignoredUpdateVersion: ''));
  }

  Future<void> setAutoReminderEnabled(bool enabled) async {
    if (_disposed) return;
    _preferenceRevision++;
    autoReminderEnabled = enabled;
    if (!enabled) _automaticRelease = null;
    _notify();
    await _writePreferences(PlayerSettings(updateReminderEnabled: enabled));
  }

  Future<PlayerSettingsStore> _resolveStore() async {
    if (_settingsStore != null) return _settingsStore;
    try {
      return await openSettingsStore!().timeout(_ioTimeout);
    } catch (_) {
      return MemoryPlayerSettingsStore();
    }
  }

  Future<void> _loadPreferences(Future<PlayerSettingsStore> opening) async {
    try {
      final store = await opening;
      final settings = await store.read().timeout(_ioTimeout);
      if (_disposed || _preferenceRevision != 0) return;
      final nextAuto = settings.isUpdateReminderEnabled;
      final nextIgnored = _normalizeVersion(
        settings.effectiveIgnoredUpdateVersion,
      );
      if (nextAuto != autoReminderEnabled || nextIgnored != ignoredVersion) {
        autoReminderEnabled = nextAuto;
        ignoredVersion = nextIgnored;
        if (!autoReminderEnabled ||
            (_automaticRelease != null &&
                isReleaseIgnored(_automaticRelease))) {
          _automaticRelease = null;
        }
        _notify();
      }
    } catch (_) {
      /* Default reminder preferences remain active when storage is unavailable. */
    } finally {
      _preferencesLoaded = true;
    }
  }

  bool get _hasPendingPreferencesLoad =>
      !_preferencesLoaded &&
      (_preferencesLoad != null ||
          _settingsStore != null ||
          openSettingsStore != null);

  Future<void> _ensurePreferencesLoaded() {
    if (_preferencesLoad != null) return _preferencesLoad!;
    if (_settingsStore != null) {
      return _preferencesLoad = _loadPreferences(Future.value(_settingsStore));
    }
    if (openSettingsStore != null) {
      return _preferencesLoad = _loadPreferences(
        _openedStore ??= _resolveStore(),
      );
    }
    return Future.value();
  }

  Future<void> _writePreferences(PlayerSettings patch) async {
    if (_settingsStore == null && openSettingsStore == null) return;
    try {
      final store = _settingsStore ?? await (_openedStore ??= _resolveStore());
      await store.writePatch(patch).timeout(_ioTimeout);
    } catch (_) {}
  }

  Future<void> checkAtStartup() {
    if (_startupChecked || _disposed) return Future.value();
    _startupChecked = true;
    if (!autoReminderEnabled &&
        _preferencesLoad == null &&
        openSettingsStore == null) {
      return Future.value();
    }
    return check(automatic: true);
  }

  Future<void> check({bool automatic = false}) {
    if (_disposed) return Future.value();
    if (automatic) _autoRequested = true;
    if (_checking != null) {
      if (!automatic && !manualCheck) {
        manualCheck = true;
        _notify();
      }
      return _checking!;
    }
    manualCheck = !automatic;
    checkPhase = UpdateCheckPhase.checking;
    checkFailure = null;
    final pending = _checking = _performCheck().whenComplete(
      () => _checking = null,
    );
    _notify();
    return pending;
  }

  Future<void> _performCheck() async {
    try {
      if (_hasPendingPreferencesLoad) {
        await _ensurePreferencesLoaded();
      }
      if (_disposed) return;
      if (_autoRequested && !manualCheck && !autoReminderEnabled) {
        checkPhase = UpdateCheckPhase.idle;
        return;
      }
      final candidate = await _service.check();
      if (_disposed) return;
      UpdateCapabilities? environment;
      try {
        environment = await platform.capabilities();
      } catch (_) {
        /* The Release page still works if platform detection fails. */
      }
      if (_disposed) return;
      release = candidate;
      capabilities = environment;
      selection = environment == null
          ? const UpdateAssetSelection.unavailable(
              UpdateAssetIssue.unknownArchitecture,
            )
          : selectUpdateAsset(candidate, environment);
      checkPhase = candidate.isNewerThan(currentVersion)
          ? UpdateCheckPhase.available
          : UpdateCheckPhase.current;
      final versionKey = _versionKey(candidate);
      if (_autoRequested &&
          autoReminderEnabled &&
          checkPhase == UpdateCheckPhase.available &&
          !_shownVersions.contains(versionKey) &&
          ignoredVersion != versionKey) {
        _automaticRelease = candidate;
      }
    } catch (error) {
      if (_disposed) return;
      checkPhase = UpdateCheckPhase.failed;
      checkFailure = _checkError(error);
    } finally {
      _autoRequested = false;
      _notify();
    }
  }

  Future<void> startDownload() async {
    if (_disposed || download.busy || installing || requestingPermission) {
      return;
    }
    final candidate = release;
    final asset = selection?.asset;
    if (candidate == null ||
        asset == null ||
        !candidate.isNewerThan(currentVersion)) {
      return;
    }
    await _download(candidate, asset);
  }

  /// Retry the original candidate, not a newer result from a concurrent check.
  Future<void> retryDownload() async {
    if (_disposed || download.busy || installing || requestingPermission) {
      return;
    }
    final candidate = download.release;
    final asset = download.asset;
    if (candidate != null && asset != null) await _download(candidate, asset);
  }

  Future<void> _download(AppRelease candidate, ReleaseAsset asset) async {
    final generation = ++_downloadGeneration;
    final token = _cancelToken = CancelToken();
    installAction = null;
    permissionAction = null;
    download = UpdateDownloadState(
      phase: UpdateDownloadPhase.downloading,
      release: candidate,
      asset: asset,
    );
    _notify();
    bool active() => !_disposed && generation == _downloadGeneration;
    try {
      final verified = await _downloader.download(
        release: candidate,
        asset: asset,
        cancelToken: token,
        onProgress: (received, total) {
          if (!active()) return;
          download = UpdateDownloadState(
            phase: UpdateDownloadPhase.downloading,
            release: candidate,
            asset: asset,
            received: received,
            total: total,
          );
          _notify();
        },
        onVerifying: () {
          if (!active()) return;
          download = UpdateDownloadState(
            phase: UpdateDownloadPhase.verifying,
            release: candidate,
            asset: asset,
            received: download.received,
            total: download.total,
          );
          _notify();
        },
      );
      if (!active()) return;
      download = UpdateDownloadState(
        phase: UpdateDownloadPhase.ready,
        release: candidate,
        asset: asset,
        received: verified.length,
        total: download.total,
        verified: verified,
      );
    } catch (error) {
      if (!active()) return;
      final failure = error is UpdateDownloadException
          ? error.failure
          : UpdateDownloadFailure.network;
      download = UpdateDownloadState(
        phase: failure == UpdateDownloadFailure.cancelled
            ? UpdateDownloadPhase.cancelled
            : UpdateDownloadPhase.failed,
        release: candidate,
        asset: asset,
        failure: failure,
        failedPhase: failure == UpdateDownloadFailure.cancelled
            ? null
            : download.phase,
      );
    } finally {
      if (active()) {
        _cancelToken = null;
        _notify();
      }
    }
  }

  void cancelDownload() {
    if (_disposed || !download.busy) return;
    _downloadGeneration++;
    _cancelToken?.cancel();
    _cancelToken = null;
    download = UpdateDownloadState(
      phase: UpdateDownloadPhase.cancelled,
      release: download.release,
      asset: download.asset,
      received: download.received,
      total: download.total,
    );
    _notify();
  }

  Future<void> openRelease({AppRelease? candidate}) async {
    final target = candidate ?? release;
    if (_disposed || openingRelease || target == null) return;
    openingRelease = true;
    releaseAction = null;
    _notify();
    try {
      releaseAction = target.isOfficial
          ? await platform.openRelease(target)
          : const UpdateActionResult(
              UpdateActionStatus.failed,
              failure: UpdateActionFailure.unavailable,
            );
    } catch (_) {
      releaseAction = const UpdateActionResult(
        UpdateActionStatus.failed,
        failure: UpdateActionFailure.systemFailure,
      );
    } finally {
      openingRelease = false;
      _notify();
    }
  }

  Future<void> install() async {
    final ready = download.verified;
    if (_disposed ||
        installing ||
        requestingPermission ||
        download.phase != UpdateDownloadPhase.ready ||
        ready == null) {
      return;
    }
    installing = true;
    installAction = null;
    permissionAction = null;
    _notify();
    try {
      if (!await _downloader.verify(ready)) {
        download = UpdateDownloadState(
          phase: UpdateDownloadPhase.failed,
          release: ready.release,
          asset: ready.asset,
          failure: UpdateDownloadFailure.checksum,
        );
        installAction = const UpdateActionResult(
          UpdateActionStatus.failed,
          failure: UpdateActionFailure.invalidFile,
        );
      } else if (!_disposed) {
        installAction = await platform.install(ready);
      }
    } catch (_) {
      installAction = const UpdateActionResult(
        UpdateActionStatus.failed,
        failure: UpdateActionFailure.systemFailure,
      );
    } finally {
      installing = false;
      _notify();
    }
  }

  Future<void> requestInstallPermission() async {
    if (_disposed ||
        installing ||
        requestingPermission ||
        installAction?.status != UpdateActionStatus.permissionRequired) {
      return;
    }
    requestingPermission = true;
    _notify();
    try {
      permissionAction = await platform.requestInstallPermission();
    } catch (_) {
      permissionAction = const UpdateActionResult(
        UpdateActionStatus.failed,
        failure: UpdateActionFailure.systemFailure,
      );
    } finally {
      requestingPermission = false;
      _notify();
    }
  }

  static UpdateCheckFailure _checkError(Object error) {
    if (error is FormatException) return UpdateCheckFailure.invalidResponse;
    if (error is TimeoutException) return UpdateCheckFailure.timeout;
    if (error is DioException) {
      if (error.response?.statusCode == 404) {
        return UpdateCheckFailure.noRelease;
      }
      if (const [403, 429].contains(error.response?.statusCode)) {
        return UpdateCheckFailure.rateLimited;
      }
      if (const [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ].contains(error.type)) {
        return UpdateCheckFailure.timeout;
      }
    }
    return UpdateCheckFailure.network;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _downloadGeneration++;
    _cancelToken?.cancel();
    _service.dispose();
    _downloader.dispose();
    super.dispose();
  }
}
