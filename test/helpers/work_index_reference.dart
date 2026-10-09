// Exhaustive grouping oracle from 914ad98; keep independent of the indexed builder.
import 'package:rillight/aggregation/identity/media_identity.dart';

class ReferenceWorkGroup {
  ReferenceWorkGroup._(List<WorkSource> sources, {String? stableKey})
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

  /// Version references require exact membership. An item-only reference asks
  /// whether this group has any version of the item; it does not establish that
  /// this is the item's only group (use ReferenceWorkIndex.groupFor for that lookup).
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
class ReferenceWorkIndex {
  final Map<SourceReference, WorkSource> _sources = {};
  List<ReferenceWorkGroup> _groups = const [];
  List<ReferenceWorkGroup> get groups => _groups;
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

  /// Resolve a full version anchor exactly, never via its item projection.
  /// Item-only anchors resolve only when all matching sources share one group;
  /// conflicting versions make such an anchor ambiguous, even if an explicit
  /// item-only source is present in one of those groups.
  ReferenceWorkGroup? groupFor(SourceReference ref) {
    final matches = _groups.where((g) => g.contains(ref)).iterator;
    if (!matches.moveNext()) return null;
    final group = matches.current;
    return matches.moveNext() ? null : group;
  }

  /// All keys are source anchors, including retired group keys after a merge.
  /// A split resolves the old key only to its actual source's new group; this
  /// cannot duplicate or transfer source-specific viewing records.
  ReferenceWorkGroup? groupForKey(String key) => _groups
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
        return ReferenceWorkGroup._(sources, stableKey: retained.firstOrNull);
      }),
    );
  }
}
