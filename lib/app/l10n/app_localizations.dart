import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('zh')];

  /// Product name shown in the window, menus, and UI.
  ///
  /// In zh, this message translates to:
  /// **'灯川 Rillight'**
  String get appName;

  /// Retry action after a visible failure.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get retry;

  /// Accessible label for a missing or failed cover image.
  ///
  /// In zh, this message translates to:
  /// **'封面不可用'**
  String get posterPlaceholder;

  /// Title of the Emby connection form.
  ///
  /// In zh, this message translates to:
  /// **'连接服务器'**
  String get connectTitle;

  /// Label for the Emby server address field.
  ///
  /// In zh, this message translates to:
  /// **'服务器地址'**
  String get serverAddress;

  /// Example Emby server address.
  ///
  /// In zh, this message translates to:
  /// **'http://192.168.1.8:8096'**
  String get serverAddressHint;

  /// Label for the Emby username field.
  ///
  /// In zh, this message translates to:
  /// **'用户名'**
  String get username;

  /// Label for the Emby password field.
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get password;

  /// Optional HTTP User-Agent for a server line.
  ///
  /// In zh, this message translates to:
  /// **'User-Agent'**
  String get userAgent;

  /// Hint that a line User-Agent is optional.
  ///
  /// In zh, this message translates to:
  /// **'可选，留空则使用默认'**
  String get userAgentHint;

  /// Submit action to connect and sign in.
  ///
  /// In zh, this message translates to:
  /// **'连接'**
  String get connect;

  /// Busy label while connecting to Emby.
  ///
  /// In zh, this message translates to:
  /// **'正在连接…'**
  String get connecting;

  /// Sign out of the current Emby session.
  ///
  /// In zh, this message translates to:
  /// **'退出登录'**
  String get logout;

  /// Heading for the list of saved Emby servers.
  ///
  /// In zh, this message translates to:
  /// **'已保存的服务器'**
  String get savedServers;

  /// Heading for the list of access lines on a saved server.
  ///
  /// In zh, this message translates to:
  /// **'线路'**
  String get lines;

  /// Action to start adding another Emby server.
  ///
  /// In zh, this message translates to:
  /// **'添加服务器'**
  String get addServer;

  /// Action to add another access line to the selected server.
  ///
  /// In zh, this message translates to:
  /// **'添加线路'**
  String get addLine;

  /// Action to delete the selected extra access line.
  ///
  /// In zh, this message translates to:
  /// **'删除线路'**
  String get deleteLine;

  /// Volume slider on the player controls.
  ///
  /// In zh, this message translates to:
  /// **'音量'**
  String get volume;

  /// Tooltip for the signed-in server menu.
  ///
  /// In zh, this message translates to:
  /// **'切换服务器'**
  String get switchServer;

  /// Logged-in status showing the Emby server name.
  ///
  /// In zh, this message translates to:
  /// **'已连接 {serverName}'**
  String connectedTo(String serverName);

  /// Visible failure when the server address cannot be parsed.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效的服务器地址'**
  String get errorInvalidAddress;

  /// Visible failure when the server address cannot be reached.
  ///
  /// In zh, this message translates to:
  /// **'无法连接服务器'**
  String get errorUnreachable;

  /// Visible failure when the Emby probe or login times out.
  ///
  /// In zh, this message translates to:
  /// **'连接超时'**
  String get errorTimeout;

  /// Visible failure for TLS certificate errors.
  ///
  /// In zh, this message translates to:
  /// **'证书错误，无法建立安全连接'**
  String get errorCertificate;

  /// Visible failure when Public Info is not an Emby server.
  ///
  /// In zh, this message translates to:
  /// **'该地址不是 Emby 服务器'**
  String get errorNotEmby;

  /// Visible failure for a rejected Emby login.
  ///
  /// In zh, this message translates to:
  /// **'用户名或密码错误'**
  String get errorInvalidCredentials;

  /// Visible failure when an Emby token is rejected with 401.
  ///
  /// In zh, this message translates to:
  /// **'会话已失效，请重新登录'**
  String get errorSessionExpired;

  /// Fallback visible failure for unexpected connection errors.
  ///
  /// In zh, this message translates to:
  /// **'连接失败'**
  String get errorUnknown;

  /// Navigation label for the signed-in home catalog.
  ///
  /// In zh, this message translates to:
  /// **'首页'**
  String get home;

  /// Home section of movie and TV library tiles.
  ///
  /// In zh, this message translates to:
  /// **'片库'**
  String get libraries;

  /// Navigation and action label for name search.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get search;

  /// Placeholder in the catalog search field.
  ///
  /// In zh, this message translates to:
  /// **'搜索电影或剧集'**
  String get searchHint;

  /// Hint shown when search has not been submitted.
  ///
  /// In zh, this message translates to:
  /// **'输入片名后搜索'**
  String get searchEmptyQuery;

  /// Empty-success copy after a completed search with no hits.
  ///
  /// In zh, this message translates to:
  /// **'没有结果'**
  String get searchNoResults;

  /// Home row title for resumable movies and episodes.
  ///
  /// In zh, this message translates to:
  /// **'继续观看'**
  String get resumeRow;

  /// Home row title for next-up TV episodes.
  ///
  /// In zh, this message translates to:
  /// **'即将播放'**
  String get nextUpRow;

  /// Home row title for recently added movies.
  ///
  /// In zh, this message translates to:
  /// **'最近添加的电影'**
  String get latestMoviesRow;

  /// Home row title for recently added series.
  ///
  /// In zh, this message translates to:
  /// **'最近添加的剧集'**
  String get latestSeriesRow;

  /// Opens the full poster wall for a media shelf.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get more;

  /// Detail shelf title for similar titles when the server returns items.
  ///
  /// In zh, this message translates to:
  /// **'更多类似'**
  String get similarRow;

  /// Detail shelf title for episodes in the selected season.
  ///
  /// In zh, this message translates to:
  /// **'集'**
  String get episodesRow;

  /// Label for the poster-wall sort control.
  ///
  /// In zh, this message translates to:
  /// **'排序'**
  String get sortBy;

  /// Sort poster walls by SortName.
  ///
  /// In zh, this message translates to:
  /// **'名称'**
  String get sortByName;

  /// Sort poster walls by DateCreated.
  ///
  /// In zh, this message translates to:
  /// **'添加日期'**
  String get sortByDateCreated;

  /// Sort poster walls by PremiereDate.
  ///
  /// In zh, this message translates to:
  /// **'首映日期'**
  String get sortByPremiereDate;

  /// Sort poster walls by CommunityRating when items include it.
  ///
  /// In zh, this message translates to:
  /// **'评分'**
  String get sortByRating;

  /// Tooltip for the shelf control that reveals posters to the left.
  ///
  /// In zh, this message translates to:
  /// **'向左'**
  String get scrollLeft;

  /// Tooltip for the shelf control that reveals posters to the right.
  ///
  /// In zh, this message translates to:
  /// **'向右'**
  String get scrollRight;

  /// Action to mark an item as played.
  ///
  /// In zh, this message translates to:
  /// **'标记已看'**
  String get markPlayed;

  /// Action to mark an item as unplayed.
  ///
  /// In zh, this message translates to:
  /// **'标记未看'**
  String get markUnplayed;

  /// Heading for an item overview.
  ///
  /// In zh, this message translates to:
  /// **'简介'**
  String get overview;

  /// Heading for a series season list.
  ///
  /// In zh, this message translates to:
  /// **'季'**
  String get seasons;

  /// How many seasons a series has.
  ///
  /// In zh, this message translates to:
  /// **'共{count}季'**
  String seasonCount(int count);

  /// Visible failure when a catalog request fails.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get errorLoadFailed;

  /// Visible failure when search HTTP or parsing fails.
  ///
  /// In zh, this message translates to:
  /// **'搜索失败'**
  String get errorSearchFailed;

  /// Visible failure when an item cannot be opened.
  ///
  /// In zh, this message translates to:
  /// **'条目不可用'**
  String get itemUnavailable;

  /// Series episode count shown on detail.
  ///
  /// In zh, this message translates to:
  /// **'{count} 集'**
  String episodeCount(int count);

  /// Runtime formatted with hours and minutes.
  ///
  /// In zh, this message translates to:
  /// **'{hours}小时{minutes}分钟'**
  String runtimeHoursMinutes(int hours, int minutes);

  /// Runtime formatted in minutes only.
  ///
  /// In zh, this message translates to:
  /// **'{minutes}分钟'**
  String runtimeMinutes(int minutes);

  /// Resume progress label on a catalog item.
  ///
  /// In zh, this message translates to:
  /// **'已看 {percent}%'**
  String playbackProgress(int percent);

  /// Start playback from the beginning.
  ///
  /// In zh, this message translates to:
  /// **'播放'**
  String get play;

  /// Opens the detail page for the featured home hero item.
  ///
  /// In zh, this message translates to:
  /// **'详情'**
  String get details;

  /// Pause playback.
  ///
  /// In zh, this message translates to:
  /// **'暂停'**
  String get pause;

  /// Resume playback from the saved position.
  ///
  /// In zh, this message translates to:
  /// **'继续播放'**
  String get resumePlay;

  /// Start playback from the beginning despite saved progress.
  ///
  /// In zh, this message translates to:
  /// **'从头播放'**
  String get playFromStart;

  /// Prompt shown when opening an item with saved progress.
  ///
  /// In zh, this message translates to:
  /// **'要从上次的位置继续播放吗？'**
  String get resumePrompt;

  /// Enter fullscreen playback.
  ///
  /// In zh, this message translates to:
  /// **'全屏'**
  String get fullscreen;

  /// Leave fullscreen playback without quitting the app.
  ///
  /// In zh, this message translates to:
  /// **'退出全屏'**
  String get exitFullscreen;

  /// Label when the session is Direct Play or Direct Stream.
  ///
  /// In zh, this message translates to:
  /// **'直连'**
  String get directPlay;

  /// Label when the server is transcoding.
  ///
  /// In zh, this message translates to:
  /// **'转码'**
  String get transcode;

  /// Automatic transcode quality preset.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get qualityAuto;

  /// Named transcode bitrate preset.
  ///
  /// In zh, this message translates to:
  /// **'{mbps} Mbps'**
  String qualityMbps(int mbps);

  /// Detail shelf of movie or episode chapters.
  ///
  /// In zh, this message translates to:
  /// **'章节'**
  String get chapters;

  /// Label for choosing a media version on the detail page.
  ///
  /// In zh, this message translates to:
  /// **'片源'**
  String get mediaSource;

  /// Audio track selector label.
  ///
  /// In zh, this message translates to:
  /// **'音轨'**
  String get audioTrack;

  /// Subtitle track selector label.
  ///
  /// In zh, this message translates to:
  /// **'字幕'**
  String get subtitleTrack;

  /// Disable subtitles.
  ///
  /// In zh, this message translates to:
  /// **'关闭字幕'**
  String get subtitleOff;

  /// Notice when PGS/bitmap subtitles are burned in by the server.
  ///
  /// In zh, this message translates to:
  /// **'该字幕为位图，将请求服务器烧录'**
  String get subtitleBitmapBurnIn;

  /// Notice when bitmap subtitles cannot be rendered on Direct Play.
  ///
  /// In zh, this message translates to:
  /// **'直连无法渲染该字幕，请改用转码'**
  String get subtitleBitmapFailed;

  /// Cancelable countdown before autoplaying the next episode.
  ///
  /// In zh, this message translates to:
  /// **'{seconds} 秒后播放下一集'**
  String nextEpisodeIn(int seconds);

  /// Cancel next-episode autoplay.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancelNextEpisode;

  /// Play the next episode now.
  ///
  /// In zh, this message translates to:
  /// **'播放下一集'**
  String get playNextEpisode;

  /// Visible failure when playback disconnects.
  ///
  /// In zh, this message translates to:
  /// **'播放中断，请检查网络'**
  String get playbackDisconnected;

  /// Visible failure when Playing/Progress/Stopped reporting fails.
  ///
  /// In zh, this message translates to:
  /// **'进度同步失败'**
  String get progressSyncFailed;

  /// Visible failure when playback cannot start.
  ///
  /// In zh, this message translates to:
  /// **'无法播放'**
  String get playbackFailed;

  /// Visible failure when PlaybackInfo has no stream.
  ///
  /// In zh, this message translates to:
  /// **'没有可播放的流'**
  String get noPlayableStream;

  /// Status shown while PlaybackInfo and the stream are loading.
  ///
  /// In zh, this message translates to:
  /// **'正在打开播放…'**
  String get playerLoading;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
