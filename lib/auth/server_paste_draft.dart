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
    var addressFirst = false;
    final pendingLines = <String>[];
    void flushLines() {
      for (final address in pendingLines) {
        if (!draft.lines.contains(address)) draft.lines.add(address);
      }
      pendingLines.clear();
    }

    void finish() {
      flushLines();
      if (draft.hasRecognizedFields) {
        groups.add(draft);
      } else {
        unknown.addAll(draft.unrecognized);
      }
      draft = ServerPasteDraft();
      addressFirst = false;
    }

    List<String> takePendingLines() {
      final next = List<String>.of(pendingLines);
      pendingLines.clear();
      return next;
    }

    void keepUnassigned(List<String> lines) {
      if (lines.isEmpty) return;
      // A partial, address-only group requires the caller to choose and supply
      // its account; never borrow credentials from either neighboring group.
      draft.lines.addAll(lines);
      finish();
    }

    void nextNamedRecord() {
      final unassigned = takePendingLines();
      finish();
      keepUnassigned(unassigned);
    }

    void nextAccount() {
      final next = takePendingLines();
      finish();
      if (next.length > 1) {
        // Several plain URLs could be backups or the next account's addresses.
        keepUnassigned(next);
      } else {
        draft.lines.addAll(next);
        addressFirst = next.isNotEmpty;
      }
    }

    void address(String value, {bool explicitLine = false}) {
      if (explicitLine) {
        // A labeled line belongs to the current server regardless of whether
        // the username/password appeared before it.
        pendingLines.remove(value);
        if (!draft.lines.contains(value)) draft.lines.add(value);
      } else if (addressFirst &&
          (draft.username.isNotEmpty || draft.password.isNotEmpty)) {
        if (!pendingLines.contains(value)) pendingLines.add(value);
      } else {
        if (draft.username.isEmpty && draft.password.isEmpty) {
          addressFirst = true;
        }
        if (!draft.lines.contains(value)) draft.lines.add(value);
      }
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
          if (draft.name.isNotEmpty ||
              draft.username.isNotEmpty ||
              draft.password.isNotEmpty) {
            nextNamedRecord();
          }
          draft.name = value;
          continue;
        }
        if (['用户名', '用户', '账号', 'username', 'user'].contains(key)) {
          if (draft.username.isNotEmpty) nextAccount();
          draft.username = value;
          continue;
        }
        if (['密码', 'password', 'pass'].contains(key)) {
          if (draft.password.isNotEmpty) nextAccount();
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
            address(
              normalizeServerAddress(value).toString(),
              explicitLine: key.startsWith('线路'),
            );
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
          address(normalizeServerAddress(trimmed).toString());
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
