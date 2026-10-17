import '../media_server/capabilities.dart';
import '../media_server/errors.dart';
import '../media_server/server_address.dart';

/// Only an explicit paste action supplies text. This object has no IO or token
/// fields and is discarded with the form; partial input remains editable.
class ServerPasteDraft {
  String name = '';
  String username = '';
  String password = '';
  MediaServerType serviceType = MediaServerType.emby;
  final List<String> lines = [];
  final List<String> unrecognized = [];
  bool get hasRecognizedFields =>
      name.isNotEmpty ||
      username.isNotEmpty ||
      password.isNotEmpty ||
      lines.isNotEmpty;
}

class ServerPastePreview {
  ServerPastePreview._(this.originalText, this.groups, this.unrecognized);
  final String originalText;
  final List<ServerPasteDraft> groups;
  final List<String> unrecognized;
  bool get needsGroupSelection => groups.length > 1;
  bool get recognized => groups.isNotEmpty;

  factory ServerPastePreview.parse(String text) {
    final groups = <ServerPasteDraft>[];
    final unknown = <String>[];
    var draft = ServerPasteDraft();
    void finish() {
      if (draft.hasRecognizedFields) {
        groups.add(draft);
      } else {
        unknown.addAll(draft.unrecognized);
      }
      draft = ServerPasteDraft();
    }

    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final field = RegExp(
        r'^(名称|服务器名称|name|用户名|用户|账号|username|user|密码|password|pass|类型|type|地址|服务器|线路\d*|url|address|server)\s*[:：=]\s*(.*)$',
        caseSensitive: false,
      ).firstMatch(trimmed);
      if (field != null) {
        final key = field[1]!.toLowerCase();
        final value = field[2]!;
        if (['名称', '服务器名称', 'name'].contains(key)) {
          if (draft.name.isNotEmpty) finish();
          draft.name = value;
          continue;
        }
        if (['用户名', '用户', '账号', 'username', 'user'].contains(key)) {
          if (draft.username.isNotEmpty) finish();
          draft.username = value;
          continue;
        }
        if (['密码', 'password', 'pass'].contains(key)) {
          if (draft.password.isNotEmpty) finish();
          draft.password = value;
          continue;
        }
        if (['类型', 'type'].contains(key)) {
          final type = MediaServerType.values
              .where((t) => t.name == value.toLowerCase())
              .firstOrNull;
          if (type != null) {
            draft.serviceType = type;
            continue;
          }
        } else {
          try {
            final address = normalizeServerAddress(value).toString();
            if (!draft.lines.contains(address)) draft.lines.add(address);
            continue;
          } on MediaServerException {
            /* keep the invalid field for correction */
          }
        }
      } else if (RegExp(
        r'^https?://',
        caseSensitive: false,
      ).hasMatch(trimmed)) {
        try {
          final address = normalizeServerAddress(trimmed).toString();
          if (!draft.lines.contains(address)) draft.lines.add(address);
          continue;
        } on MediaServerException {
          /* do not silently drop a credential URL */
        }
      }
      draft.unrecognized.add(raw);
    }
    finish();
    return ServerPastePreview._(
      text,
      List.unmodifiable(groups),
      List.unmodifiable(unknown),
    );
  }
}
