import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';

class PosterPlaceholder extends StatelessWidget {
  const PosterPlaceholder({
    super.key,
    this.width,
    this.height,
    this.semanticLabel,
  });

  final double? width;
  final double? height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      label: semanticLabel ?? l10n.posterPlaceholder,
      child: SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Icon(
              Icons.movie_outlined,
              color: colorScheme.onSurfaceVariant,
              size: 36,
            ),
          ),
        ),
      ),
    );
  }
}
