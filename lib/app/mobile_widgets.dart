import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/media_image/media_image.dart';

class MobileFailure extends StatelessWidget {
  const MobileFailure({super.key, required this.error, required this.retry});
  final EmbyException error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(embyFailureMessage(l, error)),
          const SizedBox(height: 8),
          FilledButton(onPressed: retry, child: Text(l.retry)),
        ],
      ),
    );
  }
}

class MobilePoster extends StatelessWidget {
  const MobilePoster({super.key, required this.item});
  final EmbyItem item;
  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => context.push(AppRoutes.item(item.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: MediaImage(item: item, maxWidth: 400)),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  );
}

class MobileGrid extends StatelessWidget {
  const MobileGrid({super.key, required this.items});
  final List<EmbyItem> items;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = (constraints.maxWidth / 165).floor().clamp(2, 6);
      final width = constraints.maxWidth / columns;
      final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      return Wrap(
        children: [
          for (final item in items)
            SizedBox(
              width: width,
              height: width * 1.5 + 52 * textScale,
              child: MobilePoster(item: item),
            ),
        ],
      );
    },
  );
}
