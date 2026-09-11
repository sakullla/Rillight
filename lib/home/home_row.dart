import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/library/poster_card.dart';

class HomeMediaRow extends StatelessWidget {
  const HomeMediaRow({
    super.key,
    required this.rowKey,
    required this.title,
    required this.state,
    required this.onTap,
    required this.onRetry,
    this.showProgress = false,
  });

  final Key rowKey;
  final String title;
  final CatalogRowState state;
  final ValueChanged<EmbyItem> onTap;
  final VoidCallback onRetry;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    if (state.hidden) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return Padding(
      key: rowKey,
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          const SizedBox(height: 12),
          if (state.loading)
            const SizedBox(height: 180)
          else if (state.error != null)
            AppErrorView(
              message: catalogFailureMessage(l10n, state.error!),
              onRetry: onRetry,
            )
          else
            SizedBox(
              height: showProgress ? 250 : 230,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemBuilder: (context, index) {
                  final item = state.items[index];
                  return PosterCard(
                    item: item,
                    showProgress: showProgress,
                    onTap: () => onTap(item),
                  );
                },
                separatorBuilder: (context, index) => const SizedBox(width: 12),
                itemCount: state.items.length,
              ),
            ),
        ],
      ),
    );
  }
}
