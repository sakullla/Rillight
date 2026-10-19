import 'dart:io';

import 'package:dio/dio.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/media_server/errors.dart';

String catalogFailureMessage(
  AppLocalizations l10n,
  MediaServerException error,
) {
  final detail = error.detail?.trim();
  if (detail != null && detail.isNotEmpty) {
    return detail;
  }
  if (error.kind == MediaServerFailureKind.unknown) {
    return l10n.errorLoadFailed;
  }
  return embyFailureMessage(l10n, error);
}

String searchFailureMessage(AppLocalizations l10n, MediaServerException error) {
  final detail = error.detail?.trim();
  if (detail != null && detail.isNotEmpty) {
    return detail;
  }
  if (error.kind == MediaServerFailureKind.unknown) {
    return l10n.errorSearchFailed;
  }
  return embyFailureMessage(l10n, error);
}

/// 首页失败/空态的可区分分类。
enum HomeFailureKind { deviceOffline, serverOffline, empty }

/// 没有网络接口时的系统错误码。Linux/Android 与 macOS/iOS 共用部分数值，
/// Windows 的 WSA 错误码独立成段。
const Set<int> _deviceOfflineCodes = {
  100, // ENETDOWN, Linux/Android
  101, // ENETUNREACH, Linux/Android
  112, // EHOSTDOWN, Linux/Android
  113, // EHOSTUNREACH, Linux/Android
  50, // ENETDOWN, macOS/iOS
  51, // ENETUNREACH, macOS/iOS
  64, // EHOSTDOWN, macOS/iOS
  65, // EHOSTUNREACH, macOS/iOS
  10050, // WSAENETDOWN, Windows
  10051, // WSAENETUNREACH, Windows
  10064, // WSAEHOSTDOWN, Windows
  10065, // WSAEHOSTUNREACH, Windows
};

/// 服务器拒绝连接：网络还在，只是目标端口没有服务。
const Set<int> _connectionRefusedCodes = {
  111, // ECONNREFUSED, Linux/Android
  61, // ECONNREFUSED, macOS/iOS
  10061, // WSAECONNREFUSED, Windows
};

/// 把首页加载错误归为设备离线、服务器离线或空库。
///
/// 无错误且没有可展示内容时是空库。[hasLibraries] 只供调用方与文案层
/// 决定空库主操作，不改变分类本身。
HomeFailureKind homeFailureKind(
  MediaServerException? error, {
  required bool hasLibraries,
}) {
  if (error == null) {
    return HomeFailureKind.empty;
  }
  if (error.kind == MediaServerFailureKind.unreachable) {
    final code = _socketErrorCodeOf(error);
    if (code != null && _deviceOfflineCodes.contains(code)) {
      return HomeFailureKind.deviceOffline;
    }
    if (code != null && _connectionRefusedCodes.contains(code)) {
      return HomeFailureKind.serverOffline;
    }
    // DNS 失败和其余不可达也算服务器离线：设备网络仍在，只是这台服务器
    // 没有响应。
    return HomeFailureKind.serverOffline;
  }
  return HomeFailureKind.serverOffline;
}

/// 首页失败/空态的标题、原因与主次操作文案。
///
/// 桌面、手机和 TV 使用同一份分类与文案，只由各自的组件负责布局。
class HomeFailureCopy {
  const HomeFailureCopy({
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.secondaryLabel,
  });

  final String title;
  final String message;
  final String primaryLabel;
  final String secondaryLabel;
}

/// 错误态的文案入口。
///
/// 只有网络不可达与超时才使用新的离线文案;认证、证书、权限等继续沿用
/// [catalogFailureMessage] 的既有分类与细节。
HomeFailureCopy homeFailureCopyForError(
  AppLocalizations l10n,
  MediaServerException? error, {
  required bool hasLibraries,
  bool hasAlternateLine = false,
}) {
  if (error != null &&
      error.kind != MediaServerFailureKind.unreachable &&
      error.kind != MediaServerFailureKind.timeout) {
    return HomeFailureCopy(
      title: l10n.homeFailureLoadFailedTitle,
      message: catalogFailureMessage(l10n, error),
      primaryLabel: l10n.retry,
      secondaryLabel: l10n.switchServer,
    );
  }
  return homeFailureCopy(
    l10n,
    homeFailureKind(error, hasLibraries: hasLibraries),
    hasLibraries: hasLibraries,
    hasAlternateLine: hasAlternateLine,
  );
}

HomeFailureCopy homeFailureCopy(
  AppLocalizations l10n,
  HomeFailureKind kind, {
  required bool hasLibraries,
  bool hasAlternateLine = false,
}) {
  switch (kind) {
    case HomeFailureKind.empty:
      return HomeFailureCopy(
        title: l10n.homeFailureEmptyTitle,
        message: hasLibraries
            ? l10n.homeFailureEmptyWithLibrariesMessage
            : l10n.homeFailureEmptyNoLibrariesMessage,
        primaryLabel: hasLibraries
            ? l10n.homeFailureGoToLibraries
            : l10n.switchServer,
        secondaryLabel: l10n.refresh,
      );
    case HomeFailureKind.deviceOffline:
      return HomeFailureCopy(
        title: l10n.homeFailureDeviceOfflineTitle,
        message: l10n.homeFailureDeviceOfflineMessage,
        primaryLabel: l10n.retry,
        secondaryLabel: l10n.switchServer,
      );
    case HomeFailureKind.serverOffline:
      return HomeFailureCopy(
        title: l10n.homeFailureServerOfflineTitle,
        message: l10n.homeFailureServerOfflineMessage,
        primaryLabel: l10n.retry,
        secondaryLabel: hasAlternateLine
            ? l10n.homeFailureSwitchRoute
            : l10n.switchServer,
      );
  }
}

int? _socketErrorCodeOf(MediaServerException error) {
  Object? current = error.cause;
  for (var i = 0; i < 8 && current != null; i++) {
    if (current is SocketException) {
      return current.osError?.errorCode;
    }
    if (current is OSError) {
      return current.errorCode;
    }
    if (current is DioException) {
      current = current.error;
      continue;
    }
    if (current is MediaServerException) {
      current = current.cause;
      continue;
    }
    break;
  }
  return null;
}
