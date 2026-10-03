import 'package:flutter/widgets.dart';

/// Include both the shelf and the page containing it. The nearest scrollable
/// alone cannot tell whether a card is moving with an outer viewport.
List<ScrollPosition> ancestorScrollPositions(BuildContext context) {
  final positions = <ScrollPosition>[];
  var scrollable = Scrollable.maybeOf(context);
  while (scrollable != null) {
    positions.add(scrollable.position);
    scrollable = Scrollable.maybeOf(scrollable.context);
  }
  return positions;
}
