import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';

/// 服务器管理界面的「库规模」块:当前服务器各类型的条目数量。
///
/// 加载中显示进度而不是 0;失败显示原因;成功时电影/剧集/单集固定展示
/// (0 也展示),其余类型按服务器返回顺序展示。
class LibraryCountsPanel extends StatelessWidget {
  const LibraryCountsPanel({
    super.key,
    required this.counts,
    required this.loading,
    required this.failure,
  });

  final LibraryCounts? counts;
  final bool loading;
  final EmbyException? failure;

  static const loadingKey = Key('library-counts-loading');
  static const failureKey = Key('library-counts-failure');

  static Key entryKey(String type) => Key('library-counts-$type');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bodySmall = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    if (loading) {
      // 静态文案而不是转圈:加载可能停在无动画的状态(如宿主测试里被冻结的
      // 后台拉取),无限动画会让 pumpAndSettle 永远等不到静止帧。
      return Text(key: loadingKey, l10n.libraryCountLoading, style: bodySmall);
    }
    final error = failure;
    if (error != null) {
      return Text(
        key: failureKey,
        embyFailureMessage(l10n, error),
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: scheme.error),
      );
    }
    final data = counts;
    if (data == null) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        _entry(l10n.libraryCountMovie, data.movie, 'Movie', bodySmall),
        _entry(l10n.libraryCountSeries, data.series, 'Series', bodySmall),
        _entry(l10n.libraryCountEpisode, data.episode, 'Episode', bodySmall),
        for (final entry in data.others)
          _entry(
            _typeLabel(l10n, entry.type),
            entry.count,
            entry.type,
            bodySmall,
          ),
      ],
    );
  }

  Widget _entry(String label, int count, String type, TextStyle? style) {
    return Text(key: entryKey(type), '$label $count', style: style);
  }

  String _typeLabel(AppLocalizations l10n, String type) {
    switch (type) {
      case 'Season':
        return l10n.libraryTypeSeason;
      case 'Trailer':
        return l10n.libraryTypeTrailer;
      case 'MusicAlbum':
        return l10n.libraryTypeMusicAlbum;
      case 'MusicArtist':
        return l10n.libraryTypeMusicArtist;
      case 'Song':
        return l10n.libraryTypeSong;
      case 'MusicVideo':
        return l10n.libraryTypeMusicVideo;
      case 'Book':
        return l10n.libraryTypeBook;
      case 'Photo':
        return l10n.libraryTypePhoto;
      case 'BoxSet':
        return l10n.libraryTypeBoxSet;
      case 'Game':
        return l10n.libraryTypeGame;
      case 'AudioPodcast':
        return l10n.libraryTypeAudioPodcast;
      default:
        return type;
    }
  }
}
