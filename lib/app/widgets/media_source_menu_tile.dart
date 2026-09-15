import 'package:flutter/material.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/emby/media_source_format.dart';

/// 片源菜单两行:规格标题 + 来源/体积补充。
class MediaSourceMenuTile extends StatelessWidget {
  const MediaSourceMenuTile({super.key, required this.view});

  final MediaSourceView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = view.detail;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            view.headline,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.68),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
