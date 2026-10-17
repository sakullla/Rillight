import 'package:rillight/auth/source_sessions.dart';

/// 详情与播放路由共用当前服务器、账号和进入许可。
OperationPermit? permitForAccount(
  SourceSessionRegistry registry,
  SourceAccount account, {
  String? libraryId,
}) {
  try {
    return registry.permit(account, libraryId: libraryId);
  } on StateError {
    return null;
  }
}

/// Whether a catalog or player route may stay open for this account.
///
/// A live local session and entry generation are required. A protected
/// server's old authorization cannot be revived from a saved URL.
bool localSessionAllowsRoute(
  SourceSessionRegistry sources,
  SourceAccount account, {
  String? libraryId,
  int? accessGeneration,
}) {
  final permit = permitForAccount(sources, account, libraryId: libraryId);
  if (permit == null || !permit.isValid) return false;
  if (!sources.access.isProtected(account.configuredServerId)) return true;
  return accessGeneration == permit.accessGeneration;
}
