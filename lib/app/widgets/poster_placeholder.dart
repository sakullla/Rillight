import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/ui/app_icons.dart';

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
    final dark = colorScheme.brightness == Brightness.dark;

    return Semantics(
      label: semanticLabel ?? l10n.posterPlaceholder,
      child: SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colorScheme.surfaceContainerHighest,
                colorScheme.surfaceContainer,
              ],
            ),
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(
                alpha: dark ? 0.45 : 0.7,
              ),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final iconExtent = (constraints.biggest.shortestSide * .22).clamp(
                16.0,
                36.0,
              );
              return Center(
                child: ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colorScheme.onSurface.withValues(
                        alpha: dark ? 0.06 : 0.05,
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(iconExtent * 0.45),
                      child: Icon(
                        AppIcons.photo,
                        fill: AppIcons.filled,
                        size: iconExtent,
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: .68,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
