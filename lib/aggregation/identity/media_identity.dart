import 'dart:convert';

import '../../auth/source_sessions.dart';
import '../../emby/emby_models.dart';

export '../../auth/source_sessions.dart' show SourceAccount;
export '../../auth/region_access.dart' show AccessRegion;

/// A value reference, not a permission. Resolve through SourceSessionRegistry
/// and use its OperationPermit at dispatch AND receipt before presenting data.
class SourceReference {
  const SourceReference({
    required this.account,
    required this.itemId,
    this.mediaSourceId,
  });
  final SourceAccount account;
  final String itemId;

  /// Null denotes an item, not an invented/default media version.
  final String? mediaSourceId;
  SourceReference get item => SourceReference(account: account, itemId: itemId);
  String get key => jsonEncode([
    account.region.name,
    account.configuredServerId,
    account.verifiedServerId,
    account.userId,
    itemId,
    mediaSourceId,
  ]);
  @override
  bool operator ==(Object other) =>
      other is SourceReference &&
      account == other.account &&
      itemId == other.itemId &&
      mediaSourceId == other.mediaSourceId;
  @override
  int get hashCode => Object.hash(account, itemId, mediaSourceId);
}

/// Provider names are case insensitive; values for recognized numeric providers
/// are normalized. Unknown providers are preserved but are NOT match evidence.
Map<String, String> normalizeProviderIds(Map<String, String> input) {
  final result = <String, String>{};
  final conflicting = <String>{};
  for (final entry in input.entries) {
    final provider = entry.key.trim().toLowerCase();
    var value = entry.value.trim();
    if (provider.isEmpty || value.isEmpty) continue;
    if (provider == 'imdb') value = value.toLowerCase();
    if (const {'tmdb', 'tvdb', 'tvmaze'}.contains(provider)) {
      value = int.tryParse(value)?.toString() ?? value;
    }
    if (result.containsKey(provider) && result[provider] != value) {
      conflicting.add(provider);
    }
    result[provider] = value;
  }
  // Do not silently accept ambiguous case-duplicate keys as a valid identity.
  if (conflicting.isNotEmpty) {
    throw FormatException('Conflicting provider aliases: $conflicting');
  }
  return Map.unmodifiable(result);
}

bool _reliable(String provider, String value) => switch (provider) {
  'imdb' => RegExp(r'^tt\d+$').hasMatch(value),
  'tmdb' || 'tvdb' || 'tvmaze' => RegExp(r'^[1-9]\d*$').hasMatch(value),
  _ => false,
};

class WorkSource {
  WorkSource({
    required this.reference,
    required this.type,
    required this.title,
    this.year,
    Map<String, String> providerIds = const {},
  }) : providerIds = normalizeProviderIds(providerIds);
  factory WorkSource.fromEmby(SourceReference reference, EmbyItem item) {
    if (reference.itemId != item.id) {
      throw ArgumentError('Item does not belong to reference');
    }
    return WorkSource(
      reference: reference,
      type: item.type,
      title: item.name,
      year: item.productionYear,
      providerIds: item.providerIds,
    );
  }
  final SourceReference reference;
  final String type;
  final String title;
  final int? year;
  final Map<String, String> providerIds;
}

enum MatchKind { confirmed, candidate, unrelated, conflict }

enum MatchReason {
  commonProvider,
  sameSourceItem,
  titleOnly,
  noCommonIdentity,
  providerConflict,
  yearConflict,
  typeConflict,
  regionConflict,
  unsupportedType,
}

class MatchDecision {
  const MatchDecision(this.kind, this.reason, {this.providers = const []});
  final MatchKind kind;
  final MatchReason reason;
  final List<String> providers;
  bool get confirmed => kind == MatchKind.confirmed;
}

String _title(String title) =>
    title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

MatchDecision compareWorks(WorkSource a, WorkSource b) {
  if (a.reference.account.region != b.reference.account.region) {
    return const MatchDecision(MatchKind.conflict, MatchReason.regionConflict);
  }
  if (a.type != b.type) {
    return const MatchDecision(MatchKind.conflict, MatchReason.typeConflict);
  }
  if (a.type != 'Movie' && a.type != 'Series') {
    return const MatchDecision(
      MatchKind.unrelated,
      MatchReason.unsupportedType,
    );
  }
  final shared = a.providerIds.keys.where(b.providerIds.containsKey).toList();
  if (shared.any((p) => a.providerIds[p] != b.providerIds[p])) {
    return const MatchDecision(
      MatchKind.conflict,
      MatchReason.providerConflict,
    );
  }
  if (a.year != null && b.year != null && a.year != b.year) {
    return const MatchDecision(MatchKind.conflict, MatchReason.yearConflict);
  }
  if (a.reference.item == b.reference.item) {
    return const MatchDecision(MatchKind.confirmed, MatchReason.sameSourceItem);
  }
  final reliable = shared.where((p) => _reliable(p, a.providerIds[p]!)).toList()
    ..sort();
  if (reliable.isNotEmpty) {
    return MatchDecision(
      MatchKind.confirmed,
      MatchReason.commonProvider,
      providers: List.unmodifiable(reliable),
    );
  }
  if (_title(a.title).isNotEmpty && _title(a.title) == _title(b.title)) {
    return const MatchDecision(MatchKind.candidate, MatchReason.titleOnly);
  }
  return const MatchDecision(MatchKind.unrelated, MatchReason.noCommonIdentity);
}

class ConfirmedLink {
  const ConfirmedLink(this.a, this.b, this.decision);
  final SourceReference a;
  final SourceReference b;
  final MatchDecision decision;
}

class WorkGroup {
  WorkGroup._(List<WorkSource> sources, {String? stableKey})
    : sources = List.unmodifiable(sources),
      key = stableKey ?? sources.first.reference.key,
      confirmations = List.unmodifiable([
        for (var i = 0; i < sources.length; i++)
          for (var j = i + 1; j < sources.length; j++)
            if (compareWorks(sources[i], sources[j]).confirmed)
              ConfirmedLink(
                sources[i].reference,
                sources[j].reference,
                compareWorks(sources[i], sources[j]),
              ),
      ]);
  final String key;
  final List<WorkSource> sources;
  final List<ConfirmedLink> confirmations;
  bool contains(SourceReference ref) =>
      sources.any((s) => s.reference.item == ref.item);
}

/// Incremental source ownership, not watch-progress ownership. Upsert replaces
/// only the same full reference. Rebuild on changed facts allows safe splits.
/// Every pair must be conflict-free, and every added member needs a reliable
/// edge; title-only candidates never bridge groups. Sorting makes paging order
/// irrelevant. Consumers keep anchors/history by source, resolving via groupFor.
class WorkIndex {
  final Map<SourceReference, WorkSource> _sources = {};
  List<WorkGroup> _groups = const [];
  List<WorkGroup> get groups => _groups;
  void upsert(Iterable<WorkSource> sources) {
    for (final source in sources) {
      _sources[source.reference] = source;
    }
    _rebuild();
  }

  void removeWhere(bool Function(SourceReference reference) predicate) {
    _sources.removeWhere((key, _) => predicate(key));
    _rebuild();
  }

  WorkGroup? groupFor(SourceReference ref) =>
      _groups.where((g) => g.contains(ref)).firstOrNull;

  /// All keys are source anchors, including retired group keys after a merge.
  /// A split resolves the old key only to its actual source's new group; this
  /// cannot duplicate or transfer source-specific viewing records.
  WorkGroup? groupForKey(String key) => _groups
      .where((g) => g.sources.any((s) => s.reference.key == key))
      .firstOrNull;
  List<WorkSource> candidatesFor(WorkSource source) => List.unmodifiable(
    _sources.values.where(
      (other) =>
          other.reference != source.reference &&
          compareWorks(source, other).kind == MatchKind.candidate,
    ),
  );
  void _rebuild() {
    final ordered = _sources.values.toList()
      ..sort((a, b) => a.reference.key.compareTo(b.reference.key));
    final groups = <List<WorkSource>>[];
    for (final source in ordered) {
      final compatible = groups.where((group) {
        final decisions = group.map((s) => compareWorks(s, source)).toList();
        return decisions.every((d) => d.kind != MatchKind.conflict) &&
            decisions.any((d) => d.confirmed);
      }).firstOrNull;
      if (compatible == null) {
        groups.add([source]);
      } else {
        compatible.add(source);
      }
    }
    // Merge compatible disconnected partitions if a later member bridges them.
    // Never merge a chain whose endpoints carry conflicting known facts.
    var changed = true;
    while (changed) {
      changed = false;
      for (var i = 0; i < groups.length && !changed; i++) {
        for (var j = i + 1; j < groups.length; j++) {
          final decisions = [
            for (final a in groups[i])
              for (final b in groups[j]) compareWorks(a, b),
          ];
          if (decisions.every((d) => d.kind != MatchKind.conflict) &&
              decisions.any((d) => d.confirmed)) {
            groups[i].addAll(groups.removeAt(j));
            groups[i].sort(
              (a, b) => a.reference.key.compareTo(b.reference.key),
            );
            changed = true;
            break;
          }
        }
      }
    }
    final previousKeys = _groups.map((g) => g.key).toSet();
    _groups = List.unmodifiable(
      groups.map((sources) {
        final retained =
            sources
                .map((s) => s.reference.key)
                .where(previousKeys.contains)
                .toList()
              ..sort();
        return WorkGroup._(sources, stableKey: retained.firstOrNull);
      }),
    );
  }
}

class EpisodeSource {
  EpisodeSource({
    required this.reference,
    required this.series,
    this.season,
    this.episode,
    this.endEpisode,
    this.isSpecial,
    this.numberingScheme,
    Map<String, String> providerIds = const {},
  }) : providerIds = normalizeProviderIds(providerIds);
  factory EpisodeSource.fromEmby(
    SourceReference reference,
    EmbyItem item, {
    String? numberingScheme,
  }) {
    if (!item.isEpisode || reference.itemId != item.id) {
      throw ArgumentError('Expected referenced episode');
    }
    return EpisodeSource(
      reference: reference,
      series: item.seriesId == null || item.seriesId!.isEmpty
          ? null
          : SourceReference(account: reference.account, itemId: item.seriesId!),
      season: item.parentIndexNumber,
      episode: item.indexNumber,
      endEpisode: item.indexNumberEnd,
      isSpecial: item.parentIndexNumber == null
          ? null
          : item.parentIndexNumber == 0,
      numberingScheme: numberingScheme,
      providerIds: item.providerIds,
    );
  }
  final SourceReference reference;
  final SourceReference? series;
  final int? season;
  final int? episode;
  final int? endEpisode;
  final bool? isSpecial;

  /// Explicitly verified mapping (e.g. aired order). Never assumed from Emby
  /// IndexNumber alone: absolute/DVD/combined episode ordering may differ.
  final String? numberingScheme;
  final Map<String, String> providerIds;
  bool get hasCoordinates =>
      season != null &&
      season! >= 0 &&
      episode != null &&
      episode! > 0 &&
      (endEpisode == null || endEpisode == episode) &&
      isSpecial != null &&
      isSpecial == (season == 0) &&
      numberingScheme != null &&
      numberingScheme!.trim().isNotEmpty;
}

enum EpisodeLookupStatus {
  confirmed,
  missing,
  uncertain,
  conflict,
  ambiguous,
  queryFailed,
}

class EpisodeLookup {
  const EpisodeLookup(this.status, {this.source});
  final EpisodeLookupStatus status;
  // Only a confirmed result supplies a direct continuation source.
  final EpisodeSource? source;
}

EpisodeLookup locateEpisode({
  required WorkGroup series,
  required EpisodeSource origin,
  required SourceAccount targetAccount,
  required Iterable<EpisodeSource> available,
  bool querySucceeded = true,
  bool complete = true,
}) {
  if (!querySucceeded) {
    return const EpisodeLookup(EpisodeLookupStatus.queryFailed);
  }
  bool belongs(EpisodeSource episode) =>
      episode.series != null &&
      episode.reference.account == episode.series!.account &&
      series.contains(episode.series!) &&
      series.sources.every((s) => s.type == 'Series');
  if (!belongs(origin) || !origin.hasCoordinates) {
    return const EpisodeLookup(EpisodeLookupStatus.uncertain);
  }
  final targetSeries = series.sources.where(
    (s) => s.reference.account == targetAccount,
  );
  if (targetSeries.isEmpty) {
    return const EpisodeLookup(EpisodeLookupStatus.uncertain);
  }
  final matches = <SourceReference, EpisodeSource>{};
  var uncertain = false;
  var conflict = false;
  for (final candidate in available) {
    if (candidate.reference.account != targetAccount) continue;
    if (!belongs(candidate) ||
        !candidate.hasCoordinates ||
        candidate.numberingScheme != origin.numberingScheme) {
      uncertain = true;
      continue;
    }
    if (candidate.season != origin.season ||
        candidate.episode != origin.episode ||
        candidate.isSpecial != origin.isSpecial) {
      continue;
    }
    final shared = origin.providerIds.keys.where(
      candidate.providerIds.containsKey,
    );
    if (shared.any((p) => origin.providerIds[p] != candidate.providerIds[p])) {
      conflict = true;
      continue;
    }
    matches[candidate.reference] = candidate;
  }
  if (conflict) return const EpisodeLookup(EpisodeLookupStatus.conflict);
  if (uncertain || !complete) {
    return const EpisodeLookup(EpisodeLookupStatus.uncertain);
  }
  if (matches.length > 1) {
    return const EpisodeLookup(EpisodeLookupStatus.ambiguous);
  }
  if (matches.isEmpty) return const EpisodeLookup(EpisodeLookupStatus.missing);
  return EpisodeLookup(
    EpisodeLookupStatus.confirmed,
    source: matches.values.single,
  );
}
