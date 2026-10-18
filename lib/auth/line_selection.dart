/// Saved user intent. The connected line belongs to the runtime session.
class LineSelection {
  const LineSelection.auto() : fixedLineId = null;
  const LineSelection.fixed(String lineId) : fixedLineId = lineId;

  final String? fixedLineId;
  bool get isAutomatic => fixedLineId == null;

  Map<String, dynamic> toJson() => {
    'mode': isAutomatic ? 'auto' : 'fixed',
    if (fixedLineId != null) 'lineId': fixedLineId,
  };

  factory LineSelection.fromJson(Object? value) {
    if (value is Map) {
      if (value['mode'] == 'auto' && !value.containsKey('lineId')) {
        return const LineSelection.auto();
      }
      final id = value['lineId'];
      if (value['mode'] == 'fixed' && id is String && id.isNotEmpty) {
        return LineSelection.fixed(id);
      }
    }
    throw const FormatException('Invalid line selection');
  }

  @override
  bool operator ==(Object other) =>
      other is LineSelection && fixedLineId == other.fixedLineId;
  @override
  int get hashCode => fixedLineId.hashCode;
}
