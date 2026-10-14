import 'package:rillight/app/ui/ui.dart';
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
    final colorScheme = AppUiTheme.of(context).colorScheme;

    return Semantics(
      label: semanticLabel ?? l10n.posterPlaceholder,
      child: SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) => Center(
              child: ExcludeSemantics(
                child: Icon(
                  CupertinoIcons.photo,
                  size: (constraints.biggest.shortestSide * .2).clamp(16, 40),
                  color: colorScheme.onSurfaceVariant.withValues(alpha: .65),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
