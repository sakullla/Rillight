import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';

/// 范围许可失败时改用仍有效的会话许可。详情门的打开和后续检查共用这一规则。
OperationPermit? permitForAccount(
  SourceSessionRegistry registry,
  SourceAccount account, {
  String? libraryId,
}) {
  try {
    return registry.permit(account, libraryId: libraryId);
  } on StateError {
    try {
      return registry.permit(account, libraryId: libraryId, sessionOnly: true);
    } on StateError {
      return null;
    }
  }
}

/// Whether a catalog or player route may stay open for this account.
///
/// Aggregation library checkboxes are a browse filter. A live local session
/// is enough to open and play that server's items, including a parent folder
/// or season id that is not itself a checked library. Private routes still
/// require the current unlock generation so a locked PIN cannot be revived
/// from a saved URL.
bool localSessionAllowsRoute(
  SourceSessionRegistry sources,
  SourceAccount account, {
  String? libraryId,
  int? regionGeneration,
}) {
  final permit = permitForAccount(sources, account, libraryId: libraryId);
  if (permit == null || !permit.isValid) return false;
  if (account.region != AccessRegion.private) return true;
  return regionGeneration == permit.regionGeneration;
}
