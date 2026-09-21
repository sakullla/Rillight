/// In-memory state for one connection flow. Never serialized to a store.
class ConnectDraft {
  ConnectDraft({required this.addingAnother});

  final bool addingAnother;
  String address = '';
  String path = '';
  String userAgent = '';
  String username = '';
  String password = '';
  String? selectedServerId;
  String? selectedLineId;
  String? appliedPrefillId;
  bool moreExpanded = false;
  List<String> extraLines = [];
}
