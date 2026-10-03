import 'package:flutter/widgets.dart';

/// Reveal a selected option on mount/selection change, never on ordinary
/// controller rebuilds. Manual browsing therefore keeps its scroll position.
class RevealSelected extends StatefulWidget {
  const RevealSelected({
    super.key,
    required this.selected,
    required this.child,
  });
  final bool selected;
  final Widget child;

  @override
  State<RevealSelected> createState() => _RevealSelectedState();
}

class _RevealSelectedState extends State<RevealSelected> {
  @override
  void initState() {
    super.initState();
    if (widget.selected) _reveal();
  }

  @override
  void didUpdateWidget(RevealSelected oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected && !oldWidget.selected) _reveal();
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.selected) return;
      Scrollable.ensureVisible(context, alignment: .5);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
