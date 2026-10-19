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
      final imported = _parseImportLink(trimmed);
      if (imported.matched) {
        // A direct link is a complete server. Keep it out of the surrounding
        // labeled lines so it cannot borrow or donate their account.
        finish();
        final link = imported.draft;
        if (link != null && link.hasRecognizedFields) {
          groups.add(link);
        } else {
          unknown.add(raw);
        }
        continue;
      }
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

/// SenPlayer `senplayer://importserver` (5.7+, documented URL scheme),
/// 小幻影视 `rodelplayer://import`, and Hills `hills://import`.
/// Hills exposes the scheme and host `import` and reads `scheme`, `host`,
/// `port`, `username`, `password`, `type` (`emby` when omitted, otherwise
/// `emby` or `jellyfin`) plus consecutive `lineN` / `lineNtitle` backup URLs.
final _importLinkPattern = RegExp(
  r'(senplayer://importserver\?\S+|rodelplayer://import\?\S+|hills://import\?\S+)',
  caseSensitive: false,
);

const _maxImportLines = 32;

({bool matched, ServerPasteDraft? draft}) _parseImportLink(String line) {
  final match = _importLinkPattern.firstMatch(line);
  if (match == null) return (matched: false, draft: null);
  var url = match.group(1)!;
  while (url.isNotEmpty && _trailingImportWrapper(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasQuery) return (matched: true, draft: null);
  Map<String, String> params;
  try {
    params = {
      for (final entry in uri.queryParameters.entries)
        entry.key.toLowerCase(): entry.value,
    };
  } on ArgumentError {
    return (matched: true, draft: null);
  } on FormatException {
    return (matched: true, draft: null);
  }
  final draft = switch (uri.scheme.toLowerCase()) {
    'senplayer' when uri.host.toLowerCase() == 'importserver' =>
      _senPlayerDraft(params),
    'rodelplayer' when uri.host.toLowerCase() == 'import' => _rodelDraft(
      params,
    ),
    'hills' when uri.host.toLowerCase() == 'import' => _hillsDraft(params),
    _ => null,
  };
  return (matched: true, draft: draft);
}

ServerPasteDraft? _senPlayerDraft(Map<String, String> params) {
  final type = _importServiceType(params['type']);
  if (type == null) return null;
  final draft = ServerPasteDraft()
    ..serviceType = type
    ..name = params['name']?.trim() ?? ''
    ..username = params['username'] ?? ''
    ..password = params['password'] ?? '';
  _addImportLine(draft, params['address']);
  for (final key in _numberedKeys(params, 'address')) {
    _addImportLine(draft, params[key]);
  }
  return draft;
}

ServerPasteDraft? _rodelDraft(Map<String, String> params) {
  final type = _importServiceType(params['type']);
  if (type == null) return null;
  final draft = ServerPasteDraft()
    ..serviceType = type
    ..name = params['title']?.trim() ?? ''
    ..username = params['username'] ?? ''
    ..password = params['password'] ?? '';
  _addImportLine(
    draft,
    _composedAddress(
      scheme: params['scheme'],
      host: params['host'],
      port: params['port'],
      path: params['path'],
    ),
  );
  for (final key in _numberedKeys(params, 'line')) {
    _addImportLine(draft, params[key]);
  }
  return draft;
}

ServerPasteDraft? _hillsDraft(Map<String, String> params) {
  final type = params.containsKey('type')
      ? _importServiceType(params['type'])
      : MediaServerType.emby;
  // Hills rejects anything other than emby or jellyfin, including an explicit
  // empty type. plex is not part of this link.
  if (type == null || type == MediaServerType.plex) return null;
  final primary = _composedAddress(
    scheme: params['scheme'],
    host: params['host'],
    port: params['port'],
  );
  if (primary == null) return null;
  final draft = ServerPasteDraft()
    ..serviceType = type
    ..username = params['username'] ?? ''
    ..password = params['password'] ?? '';
  _addImportLine(draft, primary);
  for (var index = 1; index <= _maxImportLines; index++) {
    final key = 'line$index';
    if (!params.containsKey(key)) break;
    _addImportLine(draft, params[key]);
  }
  return draft;
}

MediaServerType? _importServiceType(String? value) {
  return switch (value?.trim().toLowerCase()) {
    'emby' => MediaServerType.emby,
    'jellyfin' => MediaServerType.jellyfin,
    'plex' => MediaServerType.plex,
    _ => null,
  };
}

String? _composedAddress({
  required String? scheme,
  required String? host,
  String? port,
  String? path,
}) {
  final normalizedScheme = scheme?.trim().toLowerCase();
  final normalizedHost = host?.trim() ?? '';
  if ((normalizedScheme != 'http' && normalizedScheme != 'https') ||
      normalizedHost.isEmpty ||
      normalizedHost.contains('/')) {
    return null;
  }
  final buffer = StringBuffer('$normalizedScheme://$normalizedHost');
  final normalizedPort = port?.trim() ?? '';
  if (normalizedPort.isNotEmpty) {
    if (int.tryParse(normalizedPort) == null) return null;
    buffer.write(':$normalizedPort');
  }
  final suffix = path?.trim() ?? '';
  if (suffix.isNotEmpty) {
    buffer.write(suffix.startsWith('/') ? suffix : '/$suffix');
  }
  return _normalizedImportAddress(buffer.toString());
}

void _addImportLine(ServerPasteDraft draft, String? value) {
  if (draft.lines.length >= _maxImportLines) return;
  final address = _normalizedImportAddress(value);
  if (address != null && !draft.lines.contains(address)) {
    draft.lines.add(address);
  }
}

String? _normalizedImportAddress(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  try {
    return normalizeServerAddress(trimmed).toString();
  } on MediaServerException {
    return null;
  }
}

bool _trailingImportWrapper(String character) {
  return '>)"\'’”'.contains(character) || character == ']';
}

List<String> _numberedKeys(Map<String, String> params, String prefix) {
  final matches = <(int, String)>[];
  final pattern = RegExp('^$prefix(\\d+)\$');
  for (final key in params.keys) {
    final match = pattern.firstMatch(key);
    if (match == null) continue;
    final index = int.tryParse(match.group(1)!);
    if (index != null) matches.add((index, key));
  }
  matches.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final match in matches.take(_maxImportLines)) match.$2];
}
