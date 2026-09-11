import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/emby/emby_models.dart';

String itemTitle(EmbyItem item) {
  final year = item.productionYear;
  if (year != null && year > 0) {
    return '${item.name} ($year)';
  }
  return item.name;
}

String? runtimeLabel(AppLocalizations l10n, EmbyItem item) {
  final ticks = item.runTimeTicks;
  if (ticks == null || ticks <= 0) {
    return null;
  }
  final minutes = (ticks / 10000000 / 60).round();
  if (minutes < 60) {
    return l10n.runtimeMinutes(minutes);
  }
  return l10n.runtimeHoursMinutes(minutes ~/ 60, minutes % 60);
}

String chapterClock(int startPositionTicks) {
  final seconds = startPositionTicks <= 0 ? 0 : startPositionTicks ~/ 10000000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remain = seconds % 60;
  if (hours > 0) {
    final mm = minutes.toString().padLeft(2, '0');
    final ss = remain.toString().padLeft(2, '0');
    return '$hours:$mm:$ss';
  }
  return '${minutes.toString().padLeft(2, '0')}:${remain.toString().padLeft(2, '0')}';
}

String episodeLabel(EmbyItem item) {
  final season = item.parentIndexNumber;
  final episode = item.indexNumber;
  if (season != null && episode != null) {
    final seasonText = season.toString().padLeft(2, '0');
    final episodeText = episode.toString().padLeft(2, '0');
    return 'S${seasonText}E$episodeText ${item.name}';
  }
  return item.name;
}
