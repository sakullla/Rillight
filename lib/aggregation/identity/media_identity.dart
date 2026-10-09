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

final _imdbId = RegExp(r'^tt\d+$');
final _numericId = RegExp(r'^[1-9]\d*$');

bool _reliable(String provider, String value) => switch (provider) {
  'imdb' => _imdbId.hasMatch(value),
  'tmdb' || 'tvdb' || 'tvmaze' => _numericId.hasMatch(value),
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
      confirmations = List.unmodifiable(_confirmations(sources));

  static Iterable<ConfirmedLink> _confirmations(
    List<WorkSource> sources,
  ) sync* {
    for (var i = 0; i < sources.length; i++) {
      for (var j = i + 1; j < sources.length; j++) {
        final decision = compareWorks(sources[i], sources[j]);
        if (decision.confirmed) {
          yield ConfirmedLink(
            sources[i].reference,
            sources[j].reference,
            decision,
          );
        }
      }
    }
  }

  final String key;
  final List<WorkSource> sources;
  final List<ConfirmedLink> confirmations;

  /// Version references require exact membership. An item-only reference asks
  /// whether this group has any version of the item; it does not establish that
  /// this is the item's only group (use WorkIndex.groupFor for that lookup).
  bool contains(SourceReference ref) => sources.any(
    (s) => ref.mediaSourceId == null
        ? s.reference.item == ref
        : s.reference == ref,
  );
}

/// Incremental source ownership, not watch-progress ownership. Upsert replaces
/// only the same full reference. Rebuild on changed facts allows safe splits.
/// Every pair must be conflict-free, and every added member needs a reliable
/// edge; title-only candidates never bridge groups. Sorting makes paging order
/// irrelevant. Consumers keep anchors/history by source, resolving via groupFor.
class WorkIndex {
  final Map<SourceReference, WorkSource> _sources = {};
  final Map<SourceReference, WorkGroup> _byReference = {};
  final Map<SourceReference, WorkGroup?> _byItem = {};
  final Map<String, WorkGroup> _byKey = {};
  List<WorkGroup> _groups = const [];
  List<WorkGroup> get groups => _groups;
  void upsert(Iterable<WorkSource> sources) {
    for (final source in sources) {
      _sources[source.reference] = source;
    }
    _rebuild();
  }

  void removeWhere(bool Function(SourceReference reference) predicate) {
    final before = _sources.length;
    _sources.removeWhere((key, _) => predicate(key));
    if (_sources.length != before) _rebuild();
  }

  /// Resolve a full version anchor exactly, never via its item projection.
  /// Item-only anchors resolve only when all matching sources share one group;
  /// conflicting versions make such an anchor ambiguous, even if an explicit
  /// item-only source is present in one of those groups.
  WorkGroup? groupFor(SourceReference ref) =>
      ref.mediaSourceId == null ? _byItem[ref] : _byReference[ref];

  /// All keys are source anchors, including retired group keys after a merge.
  /// A split resolves the old key only to its actual source's new group; this
  /// cannot duplicate or transfer source-specific viewing records.
  WorkGroup? groupForKey(String key) => _byKey[key];
  List<WorkSource> candidatesFor(WorkSource source) => List.unmodifiable(
    _sources.values.where(
      (other) =>
          other.reference != source.reference &&
          compareWorks(source, other).kind == MatchKind.candidate,
    ),
  );

  // A confirmed edge requires one of these exact facts. They only narrow the
  // candidates: compareWorks still checks every pair for conflicting facts.
  static Iterable<Object> _evidence(WorkSource source) sync* {
    if (source.type != 'Movie' && source.type != 'Series') return;
    final region = source.reference.account.region;
    yield (region, source.type, source.reference.item);
    for (final entry in source.providerIds.entries) {
      if (_reliable(entry.key, entry.value)) {
        yield (region, source.type, entry.key, entry.value);
      }
    }
  }

  static bool _compatible(List<WorkSource> a, List<WorkSource> b) {
    var confirmed = false;
    for (final left in a) {
      for (final right in b) {
        final decision = compareWorks(left, right);
        if (decision.kind == MatchKind.conflict) return false;
        confirmed |= decision.confirmed;
      }
    }
    return confirmed;
  }

  void _rebuild() {
    final keys = {
      for (final source in _sources.values)
        source.reference: source.reference.key,
    };
    final ordered = _sources.values.toList()
      ..sort((a, b) => keys[a.reference]!.compareTo(keys[b.reference]!));
    final groups = <List<WorkSource>>[];
    final evidence = <Set<Object>>[];
    final postings = <Object, Set<int>>{};
    for (final source in ordered) {
      final facts = _evidence(source).toSet();
      final candidates = <int>{
        for (final fact in facts) ...?postings[fact],
      }.toList()..sort();
      final compatible = candidates
          .where((id) => _compatible(groups[id], [source]))
          .firstOrNull;
      final id = compatible ?? groups.length;
      if (compatible == null) {
        groups.add([source]);
        evidence.add(facts);
      } else {
        groups[id].add(source);
        evidence[id].addAll(facts);
      }
      for (final fact in facts) {
        (postings[fact] ??= {}).add(id);
      }
    }
    // Merge compatible disconnected partitions if a later member bridges them.
    // Never merge a chain whose endpoints carry conflicting known facts.
    var changed = true;
    while (changed) {
      changed = false;
      for (var i = 0; i < groups.length && !changed; i++) {
        if (groups[i].isEmpty) continue;
        final candidates = <int>{
          for (final fact in evidence[i]) ...postings[fact]!,
        }.where((id) => id > i).toList()..sort();
        for (final j in candidates) {
          if (_compatible(groups[i], groups[j])) {
            groups[i].addAll(groups[j]);
            groups[j].clear();
            groups[i].sort(
              (a, b) => keys[a.reference]!.compareTo(keys[b.reference]!),
            );
            for (final fact in evidence[j]) {
              postings[fact]!
                ..remove(j)
                ..add(i);
            }
            evidence[i].addAll(evidence[j]);
            evidence[j].clear();
            changed = true;
            break;
          }
        }
      }
    }
    final previousKeys = _groups.map((g) => g.key).toSet();
    _groups = List.unmodifiable(
      groups.where((sources) => sources.isNotEmpty).map((sources) {
        final retained =
            sources
                .map((s) => keys[s.reference]!)
                .where(previousKeys.contains)
                .toList()
              ..sort();
        return WorkGroup._(sources, stableKey: retained.firstOrNull);
      }),
    );
    _byReference.clear();
    _byItem.clear();
    _byKey.clear();
    for (final group in _groups) {
      for (final source in group.sources) {
        final ref = source.reference;
        _byReference[ref] = group;
        _byKey[keys[ref]!] = group;
        final item = ref.item;
        if (!_byItem.containsKey(item)) {
          _byItem[item] = group;
        } else if (!identical(_byItem[item], group)) {
          _byItem[item] = null;
        }
      }
    }
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
