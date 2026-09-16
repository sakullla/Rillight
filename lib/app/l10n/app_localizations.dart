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

  /// Shown when a capability such as chapter thumbnails is unavailable.
  ///
  /// In zh, this message translates to:
  /// **'不支持'**
  String get unsupported;

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

  /// Tooltip to reveal the connect-form password.
  ///
  /// In zh, this message translates to:
  /// **'显示密码'**
  String get showPassword;

  /// Tooltip to hide the connect-form password.
  ///
  /// In zh, this message translates to:
  /// **'隐藏密码'**
  String get hidePassword;

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

  /// Empty state when no Emby server has been saved yet.
  ///
  /// In zh, this message translates to:
  /// **'暂无已保存的服务器'**
  String get noSavedServers;

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

  /// Address field for an extra access line on the connect form.
  ///
  /// In zh, this message translates to:
  /// **'线路地址'**
  String get extraLineAddress;

  /// Filter field for a long list of saved Emby servers.
  ///
  /// In zh, this message translates to:
  /// **'搜索服务器'**
  String get searchServers;

  /// How many access lines a saved server has.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条线路'**
  String lineCount(int count);

  /// Volume slider on the player controls.
  ///
  /// In zh, this message translates to:
  /// **'音量'**
  String get volume;

  /// Mute playback from the volume icon.
  ///
  /// In zh, this message translates to:
  /// **'静音'**
  String get mute;

  /// Restore volume from the muted volume icon.
  ///
  /// In zh, this message translates to:
  /// **'取消静音'**
  String get unmute;

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

  /// Action to choose which libraries appear in the top bar and their order.
  ///
  /// In zh, this message translates to:
  /// **'自定义导航'**
  String get customizeNav;

  /// Explains the pin limit in the customize-nav dialog.
  ///
  /// In zh, this message translates to:
  /// **'最多勾选 {count} 个。顶栏放不下的会进「更多」。未勾选的不出现在导航、更多和首页片库。'**
  String customizeNavHint(int count);

  /// Save customized library navigation.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get saveNav;

  /// Move a pinned library up in the top-bar order.
  ///
  /// In zh, this message translates to:
  /// **'上移'**
  String get moveNavUp;

  /// Move a pinned library down in the top-bar order.
  ///
  /// In zh, this message translates to:
  /// **'下移'**
  String get moveNavDown;

  /// Volume level as a percentage next to the player slider.
  ///
  /// In zh, this message translates to:
  /// **'{percent}%'**
  String volumePercent(int percent);

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

  /// Hover action to hide an item from Continue Watching.
  ///
  /// In zh, this message translates to:
  /// **'从继续观看移除'**
  String get removeFromResume;

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

  /// Home row title for recently updated movies.
  ///
  /// In zh, this message translates to:
  /// **'最近更新的电影'**
  String get latestMoviesRow;

  /// Home row title for recently updated series.
  ///
  /// In zh, this message translates to:
  /// **'最近更新的剧集'**
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

  /// Episode detail shelf title for the season's episode strip used to switch episodes.
  ///
  /// In zh, this message translates to:
  /// **'本季分集'**
  String get seasonEpisodes;

  /// Appends the next window of episodes on the detail page; distinct from the shelf 'more' grid link.
  ///
  /// In zh, this message translates to:
  /// **'加载更多'**
  String get episodesLoadMore;

  /// Label for the poster-wall sort control.
  ///
  /// In zh, this message translates to:
  /// **'排序'**
  String get sortBy;

  /// Single library filter control that opens type, watch, year, and genre options.
  ///
  /// In zh, this message translates to:
  /// **'筛选'**
  String get libraryFilter;

  /// Clears every active library filter.
  ///
  /// In zh, this message translates to:
  /// **'清除筛选'**
  String get libraryFilterClear;

  /// Discards staged filter changes and closes the filter panel without applying.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get libraryFilterCancel;

  /// Minimizes the player window to the taskbar.
  ///
  /// In zh, this message translates to:
  /// **'最小化'**
  String get minimizeWindow;

  /// Library filter dimension for Movie vs Series.
  ///
  /// In zh, this message translates to:
  /// **'类型'**
  String get libraryFilterType;

  /// Library filter dimension for played vs unplayed.
  ///
  /// In zh, this message translates to:
  /// **'观看状态'**
  String get libraryFilterWatch;

  /// Library filter dimension for production year.
  ///
  /// In zh, this message translates to:
  /// **'年份'**
  String get libraryFilterYear;

  /// Library filter dimension for genre.
  ///
  /// In zh, this message translates to:
  /// **'流派'**
  String get libraryFilterGenre;

  /// Clears one library filter dimension.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get libraryFilterAll;

  /// Sort poster walls by SortName A to Z.
  ///
  /// In zh, this message translates to:
  /// **'标题'**
  String get sortByName;

  /// Default library sort by DateLastContentAdded, newest first.
  ///
  /// In zh, this message translates to:
  /// **'更新日期'**
  String get sortByDateUpdated;

  /// Sort poster walls by DateCreated, newest first.
  ///
  /// In zh, this message translates to:
  /// **'加入日期'**
  String get sortByDateCreated;

  /// Sort poster walls by PremiereDate, newest first.
  ///
  /// In zh, this message translates to:
  /// **'首映日期'**
  String get sortByPremiereDate;

  /// Sort poster walls by CommunityRating.
  ///
  /// In zh, this message translates to:
  /// **'IMDb评分'**
  String get sortByCommunityRating;

  /// Sort poster walls by CriticRating.
  ///
  /// In zh, this message translates to:
  /// **'影评人评分'**
  String get sortByCriticRating;

  /// Sort poster walls by ProductionYear.
  ///
  /// In zh, this message translates to:
  /// **'出品年份'**
  String get sortByProductionYear;

  /// Sort poster walls by OfficialRating.
  ///
  /// In zh, this message translates to:
  /// **'官方评级'**
  String get sortByOfficialRating;

  /// Sort poster walls by DatePlayed.
  ///
  /// In zh, this message translates to:
  /// **'播放日期'**
  String get sortByDatePlayed;

  /// Sort poster walls by Runtime.
  ///
  /// In zh, this message translates to:
  /// **'播放时长'**
  String get sortByRuntime;

  /// Shuffle poster walls with SortBy=Random.
  ///
  /// In zh, this message translates to:
  /// **'随机'**
  String get sortByRandom;

  /// Legacy alias for community rating sort.
  ///
  /// In zh, this message translates to:
  /// **'IMDb评分'**
  String get sortByRating;

  /// Sort episode walls by IndexNumber.
  ///
  /// In zh, this message translates to:
  /// **'集数'**
  String get sortByIndexNumber;

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

  /// Tooltip for the library page header control that switches between media libraries.
  ///
  /// In zh, this message translates to:
  /// **'切换媒体库'**
  String get switchLibrary;

  /// Tooltip for the control that collapses the side navigation.
  ///
  /// In zh, this message translates to:
  /// **'收起导航'**
  String get collapseNav;

  /// Tooltip for the floating control that expands the side navigation.
  ///
  /// In zh, this message translates to:
  /// **'展开导航'**
  String get expandNav;

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

  /// Start the named episode from a series detail page.
  ///
  /// In zh, this message translates to:
  /// **'播放 {code}'**
  String playEpisode(String code);

  /// Resume the named episode from a series detail page.
  ///
  /// In zh, this message translates to:
  /// **'继续播放 {code}'**
  String resumePlayEpisode(String code);

  /// Open the parent series from an episode detail page.
  ///
  /// In zh, this message translates to:
  /// **'查看剧集'**
  String get viewSeries;

  /// Open the next episode from an episode detail page.
  ///
  /// In zh, this message translates to:
  /// **'下一集'**
  String get nextEpisode;

  /// Scroll the episode shelf so the current episode is visible.
  ///
  /// In zh, this message translates to:
  /// **'跳转到此集'**
  String get locateEpisode;

  /// Open a picker to jump to a specific episode number.
  ///
  /// In zh, this message translates to:
  /// **'选集'**
  String get pickEpisode;

  /// Hint for typing an episode number in the picker.
  ///
  /// In zh, this message translates to:
  /// **'输入集数，回车跳转'**
  String get jumpToEpisodeHint;

  /// Reserved label for an episode that is actually playing.
  ///
  /// In zh, this message translates to:
  /// **'正在观看'**
  String get nowPlayingEpisode;

  /// Start playback from the beginning despite saved progress.
  ///
  /// In zh, this message translates to:
  /// **'从头播放'**
  String get playFromStart;

  /// Title shown when a movie or last episode finishes.
  ///
  /// In zh, this message translates to:
  /// **'播放结束'**
  String get playbackEnded;

  /// Restart the current item from the beginning after it ends.
  ///
  /// In zh, this message translates to:
  /// **'重播'**
  String get replay;

  /// Leave the player after playback ends.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get closePlayer;

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

  /// Transcode bitrate selector label in the player overflow menu.
  ///
  /// In zh, this message translates to:
  /// **'画质'**
  String get quality;

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

  /// Main-window snackbar when the host fails to relay a Stopped report for a closed player.
  ///
  /// In zh, this message translates to:
  /// **'播放进度未能同步'**
  String get progressSyncFailedMain;

  /// Player banner when the Emby token is rejected with 401 and progress reporting stops.
  ///
  /// In zh, this message translates to:
  /// **'会话已过期，进度无法保存'**
  String get playbackSessionExpired;

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

  /// Top-bar entry and page title for app settings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settings;

  /// Settings section title for playback options.
  ///
  /// In zh, this message translates to:
  /// **'播放'**
  String get settingsPlayback;

  /// Setting row label for the on-disk playback cache size limit.
  ///
  /// In zh, this message translates to:
  /// **'磁盘缓冲上限'**
  String get settingsDiskCacheLimit;

  /// Short explanation under the disk cache limit row.
  ///
  /// In zh, this message translates to:
  /// **'限制本地缓冲占用'**
  String get settingsDiskCacheLimitHint;

  /// Setting row label for hardware decoding mode.
  ///
  /// In zh, this message translates to:
  /// **'硬件解码'**
  String get settingsHardwareDecoding;

  /// Short explanation under the hardware decoding row.
  ///
  /// In zh, this message translates to:
  /// **'用显卡解码，降低 CPU 占用'**
  String get settingsHardwareDecodingHint;

  /// Hardware decoding follows the platform default.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get settingsHardwareDecodingAuto;

  /// Force hardware decoding on.
  ///
  /// In zh, this message translates to:
  /// **'开启'**
  String get settingsHardwareDecodingOn;

  /// Force hardware decoding off.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get settingsHardwareDecodingOff;

  /// Setting row label for the hardware decoder backend.
  ///
  /// In zh, this message translates to:
  /// **'解码后端'**
  String get settingsDecoderBackend;

  /// Short explanation under the decoder backend row.
  ///
  /// In zh, this message translates to:
  /// **'不确定时保持自动即可'**
  String get settingsDecoderBackendHint;

  /// Decoder backend follows the platform default.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get settingsBackendAuto;

  /// Direct3D 11 decoder backend on Windows.
  ///
  /// In zh, this message translates to:
  /// **'D3D11VA'**
  String get settingsBackendD3d11va;

  /// NVIDIA NVDEC decoder backend on Windows.
  ///
  /// In zh, this message translates to:
  /// **'NVDEC'**
  String get settingsBackendNvdec;

  /// VideoToolbox decoder backend on macOS.
  ///
  /// In zh, this message translates to:
  /// **'VideoToolbox'**
  String get settingsBackendVideotoolbox;

  /// Reset playback settings to defaults.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认'**
  String get settingsRestoreDefaults;

  /// Hint that playback settings apply to newly started playback.
  ///
  /// In zh, this message translates to:
  /// **'更改对新起播生效'**
  String get settingsAppliesToNewPlayback;

  /// Disk cache size limit shown in GB.
  ///
  /// In zh, this message translates to:
  /// **'{gb} GB'**
  String settingsCacheSize(double gb);

  /// Settings section title for the danmaku service source.
  ///
  /// In zh, this message translates to:
  /// **'弹幕服务'**
  String get settingsDanmakuService;

  /// Short explanation under the danmaku service section title.
  ///
  /// In zh, this message translates to:
  /// **'官方源需 AppId；国产剧可改用兼容自建服务'**
  String get settingsDanmakuServiceHint;

  /// Tooltip to reveal the danmaku access token.
  ///
  /// In zh, this message translates to:
  /// **'显示令牌'**
  String get settingsShowToken;

  /// Tooltip to hide the danmaku access token.
  ///
  /// In zh, this message translates to:
  /// **'隐藏令牌'**
  String get settingsHideToken;

  /// Setting row label for the custom danmaku server address.
  ///
  /// In zh, this message translates to:
  /// **'自定义服务地址'**
  String get settingsDanmakuServer;

  /// Hint that an empty custom danmaku server falls back to the official source.
  ///
  /// In zh, this message translates to:
  /// **'留空使用官方源'**
  String get settingsDanmakuServerHint;

  /// Setting row label for the official dandanplay AppId.
  ///
  /// In zh, this message translates to:
  /// **'官方 AppId'**
  String get settingsDanmakuAppId;

  /// Hint that the official danmaku source requires an AppId.
  ///
  /// In zh, this message translates to:
  /// **'官方源必填，在弹弹play 开放平台申请'**
  String get settingsDanmakuAppIdHint;

  /// Setting row label for AppSecret or a custom service token.
  ///
  /// In zh, this message translates to:
  /// **'访问令牌'**
  String get settingsDanmakuToken;

  /// Hint covering official AppSecret and custom Bearer token.
  ///
  /// In zh, this message translates to:
  /// **'官方源填 AppSecret；自定义服务填访问令牌'**
  String get settingsDanmakuTokenHint;

  /// Playback speed selector label on the player controls.
  ///
  /// In zh, this message translates to:
  /// **'倍速'**
  String get playbackRate;

  /// Player overflow control for speed, audio, quality, source, and skip settings.
  ///
  /// In zh, this message translates to:
  /// **'播放设置'**
  String get playerPlaybackSettings;

  /// Keep the player window above other windows.
  ///
  /// In zh, this message translates to:
  /// **'窗口置顶'**
  String get alwaysOnTop;

  /// Stop keeping the player window above other windows.
  ///
  /// In zh, this message translates to:
  /// **'取消置顶'**
  String get alwaysOnTopOff;

  /// Player control to open the in-player episode list panel.
  ///
  /// In zh, this message translates to:
  /// **'剧集'**
  String get playerEpisodes;

  /// Skip forward past the current intro segment.
  ///
  /// In zh, this message translates to:
  /// **'跳过片头'**
  String get skipIntro;

  /// Skip forward past the current outro segment.
  ///
  /// In zh, this message translates to:
  /// **'跳过片尾'**
  String get skipOutro;

  /// Danmaku (bullet comments) toggle in the player controls.
  ///
  /// In zh, this message translates to:
  /// **'弹幕'**
  String get danmaku;

  /// Danmaku display settings menu tooltip.
  ///
  /// In zh, this message translates to:
  /// **'弹幕设置'**
  String get danmakuSettings;

  /// Danmaku opacity setting section.
  ///
  /// In zh, this message translates to:
  /// **'不透明度'**
  String get danmakuOpacity;

  /// Danmaku font size setting section.
  ///
  /// In zh, this message translates to:
  /// **'字号'**
  String get danmakuFontSize;

  /// Danmaku scroll speed setting section.
  ///
  /// In zh, this message translates to:
  /// **'弹幕速度'**
  String get danmakuSpeed;

  /// Danmaku display area (top fraction of screen) setting section.
  ///
  /// In zh, this message translates to:
  /// **'显示区域'**
  String get danmakuDisplayArea;

  /// Danmaku on-screen density limit setting section.
  ///
  /// In zh, this message translates to:
  /// **'同屏数量'**
  String get danmakuDensity;

  /// Option for unlimited danmaku density.
  ///
  /// In zh, this message translates to:
  /// **'不限'**
  String get danmakuUnlimited;

  /// Open manual danmaku match search.
  ///
  /// In zh, this message translates to:
  /// **'手动搜索'**
  String get danmakuSearch;

  /// Title of the danmaku search dialogs.
  ///
  /// In zh, this message translates to:
  /// **'搜索弹幕'**
  String get danmakuSearchTitle;

  /// Hint text of the danmaku search keyword field.
  ///
  /// In zh, this message translates to:
  /// **'输入动画或影视名称'**
  String get danmakuSearchHint;

  /// On-player chip when auto match failed; tap opens search.
  ///
  /// In zh, this message translates to:
  /// **'未匹配到弹幕，点此搜索'**
  String get danmakuMatchHint;

  /// Danmaku match status when nothing matched.
  ///
  /// In zh, this message translates to:
  /// **'未匹配到弹幕'**
  String get danmakuNoMatch;

  /// Danmaku match status while resolving.
  ///
  /// In zh, this message translates to:
  /// **'弹幕匹配中…'**
  String get danmakuMatching;

  /// Danmaku status showing the matched anime title.
  ///
  /// In zh, this message translates to:
  /// **'已匹配：{title}'**
  String danmakuMatchedTo(String title);

  /// Banner shown when the custom danmaku service is unreachable.
  ///
  /// In zh, this message translates to:
  /// **'自定义弹幕服务不可用'**
  String get danmakuCustomUnreachable;

  /// Action to fall back to the official danmaku source.
  ///
  /// In zh, this message translates to:
  /// **'使用官方源'**
  String get danmakuUseOfficial;

  /// Danmaku source label for the official API.
  ///
  /// In zh, this message translates to:
  /// **'官方源'**
  String get danmakuOfficial;

  /// Danmaku source label for a custom compatible service.
  ///
  /// In zh, this message translates to:
  /// **'自定义源'**
  String get danmakuCustom;

  /// Danmaku status when the official source is unreachable.
  ///
  /// In zh, this message translates to:
  /// **'弹幕服务不可达'**
  String get danmakuOfficialUnreachable;

  /// Danmaku status when official AppId and AppSecret are missing.
  ///
  /// In zh, this message translates to:
  /// **'未配置 AppId'**
  String get danmakuOfficialNeedsAuth;

  /// Explains that official danmaku auth is configured in the main window.
  ///
  /// In zh, this message translates to:
  /// **'在主窗口「设置 → 弹幕服务」填写官方 AppId 与 AppSecret，或改用自定义服务。'**
  String get danmakuOfficialSetupHint;

  /// Danmaku status when the matched episode has no comments.
  ///
  /// In zh, this message translates to:
  /// **'本集无弹幕'**
  String get danmakuNoComments;

  /// Section header listing episodes of a searched anime.
  ///
  /// In zh, this message translates to:
  /// **'分集'**
  String get danmakuEpisodes;

  /// Episode detail section title for the plot overview.
  ///
  /// In zh, this message translates to:
  /// **'概览'**
  String get detailOverview;

  /// Episode detail section title for cast and crew.
  ///
  /// In zh, this message translates to:
  /// **'演职员'**
  String get detailCast;

  /// Episode detail section title for media stream information.
  ///
  /// In zh, this message translates to:
  /// **'媒体信息'**
  String get detailMediaInfo;

  /// Episode detail section title for secondary metadata such as the date added.
  ///
  /// In zh, this message translates to:
  /// **'元数据'**
  String get detailMetadata;

  /// Expands a truncated overview to full text.
  ///
  /// In zh, this message translates to:
  /// **'展开'**
  String get expand;

  /// Collapses an expanded overview back to a few lines.
  ///
  /// In zh, this message translates to:
  /// **'收起'**
  String get collapse;

  /// Episode premiere/air date label, date formatted yyyy-MM-dd.
  ///
  /// In zh, this message translates to:
  /// **'首播 {date}'**
  String premiereDate(String date);

  /// Label for the date an item was added to the library.
  ///
  /// In zh, this message translates to:
  /// **'入库日期'**
  String get dateAdded;

  /// Episode meta chip for the library add date, date formatted yyyy-MM-dd.
  ///
  /// In zh, this message translates to:
  /// **'入库 {date}'**
  String dateAddedOn(String date);

  /// Cast group label for actors.
  ///
  /// In zh, this message translates to:
  /// **'演员'**
  String get personTypeActor;

  /// Cast group label for directors.
  ///
  /// In zh, this message translates to:
  /// **'导演'**
  String get personTypeDirector;

  /// Cast group label for writers.
  ///
  /// In zh, this message translates to:
  /// **'编剧'**
  String get personTypeWriter;

  /// Cast group label for crew members of other types.
  ///
  /// In zh, this message translates to:
  /// **'其他'**
  String get personTypeOther;

  /// Media stream group label for video tracks.
  ///
  /// In zh, this message translates to:
  /// **'视频'**
  String get videoTrack;

  /// Audio channel count in media stream information.
  ///
  /// In zh, this message translates to:
  /// **'{channels} 声道'**
  String audioChannels(int channels);
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
