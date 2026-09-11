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
