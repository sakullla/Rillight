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

  /// No description provided for @sourceManagement.
  ///
  /// In zh, this message translates to:
  /// **'服务与范围管理'**
  String get sourceManagement;

  /// No description provided for @privateSetPin.
  ///
  /// In zh, this message translates to:
  /// **'设置 PIN'**
  String get privateSetPin;

  /// No description provided for @privatePin.
  ///
  /// In zh, this message translates to:
  /// **'PIN（4–12 位数字）'**
  String get privatePin;

  /// No description provided for @privateConfirmPin.
  ///
  /// In zh, this message translates to:
  /// **'再次输入 PIN'**
  String get privateConfirmPin;

  /// No description provided for @privateUnlock.
  ///
  /// In zh, this message translates to:
  /// **'解锁'**
  String get privateUnlock;

  /// No description provided for @privateLock.
  ///
  /// In zh, this message translates to:
  /// **'立即锁定'**
  String get privateLock;

  /// No description provided for @privatePinFailure.
  ///
  /// In zh, this message translates to:
  /// **'PIN 错误或操作失败，请稍后重试'**
  String get privatePinFailure;

  /// No description provided for @privateRateLimited.
  ///
  /// In zh, this message translates to:
  /// **'尝试过于频繁，请等待重试时间后再解锁'**
  String get privateRateLimited;

  /// No description provided for @sourceParticipates.
  ///
  /// In zh, this message translates to:
  /// **'参与聚合'**
  String get sourceParticipates;

  /// No description provided for @sourceDiscoverLibraries.
  ///
  /// In zh, this message translates to:
  /// **'读取媒体库（不自动选择）'**
  String get sourceDiscoverLibraries;

  /// No description provided for @sourceScopeUnknown.
  ///
  /// In zh, this message translates to:
  /// **'范围未知；请读取并明确选择媒体库'**
  String get sourceScopeUnknown;

  /// No description provided for @sourceIndependentLogin.
  ///
  /// In zh, this message translates to:
  /// **'独立账号登录'**
  String get sourceIndependentLogin;

  /// No description provided for @sourceManualCheck.
  ///
  /// In zh, this message translates to:
  /// **'手动检查'**
  String get sourceManualCheck;

  /// No description provided for @sourceMovePrivate.
  ///
  /// In zh, this message translates to:
  /// **'移入私密区域'**
  String get sourceMovePrivate;

  /// No description provided for @sourceMoveOrdinary.
  ///
  /// In zh, this message translates to:
  /// **'移入普通区域'**
  String get sourceMoveOrdinary;

  /// No description provided for @sourceMoveWarning.
  ///
  /// In zh, this message translates to:
  /// **'将先撤销该服务的展示、播放和缓存，再迁移成员关系。失败后需重新打开来源；不会自动恢复播放。'**
  String get sourceMoveWarning;

  /// No description provided for @sourceOperationFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败或访问已撤销；未自动切换来源，请重新检查'**
  String get sourceOperationFailed;

  /// No description provided for @sourceRenameLine.
  ///
  /// In zh, this message translates to:
  /// **'线路昵称'**
  String get sourceRenameLine;

  /// No description provided for @switchManual.
  ///
  /// In zh, this message translates to:
  /// **'手动切换'**
  String get switchManual;

  /// No description provided for @playbackLine.
  ///
  /// In zh, this message translates to:
  /// **'线路'**
  String get playbackLine;

  /// No description provided for @playbackLineInUse.
  ///
  /// In zh, this message translates to:
  /// **'正在使用'**
  String get playbackLineInUse;

  /// No description provided for @playbackLineFailed.
  ///
  /// In zh, this message translates to:
  /// **'线路切换失败，已继续使用原来的线路：{reason}'**
  String playbackLineFailed(String reason);

  /// No description provided for @switchLine.
  ///
  /// In zh, this message translates to:
  /// **'连接线路（同一服务）'**
  String get switchLine;

  /// No description provided for @switchVersion.
  ///
  /// In zh, this message translates to:
  /// **'来源版本（当前条目）'**
  String get switchVersion;

  /// No description provided for @switchCrossSource.
  ///
  /// In zh, this message translates to:
  /// **'跨服务来源（已确认作品）'**
  String get switchCrossSource;

  /// No description provided for @switchActual.
  ///
  /// In zh, this message translates to:
  /// **'实际播放来源'**
  String get switchActual;

  /// No description provided for @switchTimeline.
  ///
  /// In zh, this message translates to:
  /// **'目标时间轴可能不同；请选择续播或从头播放'**
  String get switchTimeline;

  /// No description provided for @switchMissingLanguage.
  ///
  /// In zh, this message translates to:
  /// **'目标缺少原语言；请选择目标音轨/字幕，或明确接受默认音轨/关闭字幕'**
  String get switchMissingLanguage;

  /// No description provided for @switchBeginning.
  ///
  /// In zh, this message translates to:
  /// **'从头播放'**
  String get switchBeginning;

  /// No description provided for @switchCurrentPosition.
  ///
  /// In zh, this message translates to:
  /// **'尝试当前位置'**
  String get switchCurrentPosition;

  /// No description provided for @switchDefaultAudio.
  ///
  /// In zh, this message translates to:
  /// **'接受默认音轨'**
  String get switchDefaultAudio;

  /// No description provided for @switchSubtitlesOff.
  ///
  /// In zh, this message translates to:
  /// **'关闭字幕'**
  String get switchSubtitlesOff;

  /// No description provided for @switchPending.
  ///
  /// In zh, this message translates to:
  /// **'正在切换；尚未确认实际播放'**
  String get switchPending;

  /// No description provided for @switchRestore.
  ///
  /// In zh, this message translates to:
  /// **'恢复原来源（需仍有访问许可）'**
  String get switchRestore;

  /// No description provided for @desktopSourceSwitchFailed.
  ///
  /// In zh, this message translates to:
  /// **'来源切换失败：目标播放窗口未能启动或就绪。未自动恢复或切换来源。'**
  String get desktopSourceSwitchFailed;

  /// No description provided for @desktopSourceRestoreUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'原来源访问许可已失效，无法恢复。'**
  String get desktopSourceRestoreUnavailable;

  /// No description provided for @desktopSourceRestoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'原来源恢复失败，请检查来源后重试。'**
  String get desktopSourceRestoreFailed;

  /// No description provided for @aggregation.
  ///
  /// In zh, this message translates to:
  /// **'聚合'**
  String get aggregation;

  /// No description provided for @aggregationLibraryScope.
  ///
  /// In zh, this message translates to:
  /// **'媒体库范围'**
  String get aggregationLibraryScope;

  /// No description provided for @aggregationPrivate.
  ///
  /// In zh, this message translates to:
  /// **'私密区域'**
  String get aggregationPrivate;

  /// No description provided for @aggregationPrivateLocked.
  ///
  /// In zh, this message translates to:
  /// **'私密区域已锁定，请先在服务管理中解锁'**
  String get aggregationPrivateLocked;

  /// No description provided for @aggregationUnavailableDetail.
  ///
  /// In zh, this message translates to:
  /// **'此来源详情当前不可访问，请返回允许的来源范围'**
  String get aggregationUnavailableDetail;

  /// No description provided for @aggregationAllowedSources.
  ///
  /// In zh, this message translates to:
  /// **'全部允许来源'**
  String get aggregationAllowedSources;

  /// No description provided for @aggregationAllSources.
  ///
  /// In zh, this message translates to:
  /// **'全部普通来源'**
  String get aggregationAllSources;

  /// No description provided for @aggregationAllTypes.
  ///
  /// In zh, this message translates to:
  /// **'全部类型'**
  String get aggregationAllTypes;

  /// No description provided for @aggregationAllWatching.
  ///
  /// In zh, this message translates to:
  /// **'全部观看状态'**
  String get aggregationAllWatching;

  /// No description provided for @aggregationContinue.
  ///
  /// In zh, this message translates to:
  /// **'继续观看'**
  String get aggregationContinue;

  /// No description provided for @aggregationRecent.
  ///
  /// In zh, this message translates to:
  /// **'最近更新'**
  String get aggregationRecent;

  /// No description provided for @aggregationLoaded.
  ///
  /// In zh, this message translates to:
  /// **'已加载作品'**
  String get aggregationLoaded;

  /// No description provided for @aggregationLoadedRemote.
  ///
  /// In zh, this message translates to:
  /// **'远端已加载作品'**
  String get aggregationLoadedRemote;

  /// No description provided for @aggregationRemoteEmpty.
  ///
  /// In zh, this message translates to:
  /// **'远端暂无继续观看项，本机记录仍可用'**
  String get aggregationRemoteEmpty;

  /// No description provided for @aggregationRemoteConflict.
  ///
  /// In zh, this message translates to:
  /// **'远端观看时间不可信，请明确选择实际来源（不取最大进度）'**
  String get aggregationRemoteConflict;

  /// No description provided for @aggregationComplete.
  ///
  /// In zh, this message translates to:
  /// **'范围完整'**
  String get aggregationComplete;

  /// No description provided for @aggregationIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'范围尚不完整 · 仅对已加载结果排序'**
  String get aggregationIncomplete;

  /// No description provided for @aggregationEmptyScope.
  ///
  /// In zh, this message translates to:
  /// **'未选择可参与的服务或媒体库'**
  String get aggregationEmptyScope;

  /// No description provided for @aggregationEmpty.
  ///
  /// In zh, this message translates to:
  /// **'所选范围没有匹配作品'**
  String get aggregationEmpty;

  /// No description provided for @aggregationAllFailed.
  ///
  /// In zh, this message translates to:
  /// **'所选来源全部失败，请逐来源重试'**
  String get aggregationAllFailed;

  /// No description provided for @aggregationPartialFailure.
  ///
  /// In zh, this message translates to:
  /// **'部分来源失败，已保留成功结果'**
  String get aggregationPartialFailure;

  /// No description provided for @aggregationRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试此来源'**
  String get aggregationRetry;

  /// No description provided for @aggregationMore.
  ///
  /// In zh, this message translates to:
  /// **'加载此来源更多'**
  String get aggregationMore;

  /// No description provided for @aggregationLocalRecord.
  ///
  /// In zh, this message translates to:
  /// **'本机确认观看记录'**
  String get aggregationLocalRecord;

  /// No description provided for @aggregationResumeActual.
  ///
  /// In zh, this message translates to:
  /// **'从本机记录的实际来源继续'**
  String get aggregationResumeActual;

  /// No description provided for @aggregationSources.
  ///
  /// In zh, this message translates to:
  /// **'查找同源'**
  String get aggregationSources;

  /// No description provided for @aggregationConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已确认来源'**
  String get aggregationConfirmed;

  /// No description provided for @aggregationCandidate.
  ///
  /// In zh, this message translates to:
  /// **'待辨认候选（非确认续播来源）'**
  String get aggregationCandidate;

  /// No description provided for @aggregationUnknown.
  ///
  /// In zh, this message translates to:
  /// **'未知'**
  String get aggregationUnknown;

  /// No description provided for @aggregationLoading.
  ///
  /// In zh, this message translates to:
  /// **'加载中'**
  String get aggregationLoading;

  /// No description provided for @aggregationAvailable.
  ///
  /// In zh, this message translates to:
  /// **'已返回'**
  String get aggregationAvailable;

  /// No description provided for @aggregationTimeout.
  ///
  /// In zh, this message translates to:
  /// **'超时'**
  String get aggregationTimeout;

  /// No description provided for @aggregationOffline.
  ///
  /// In zh, this message translates to:
  /// **'离线'**
  String get aggregationOffline;

  /// No description provided for @aggregationNeedsLogin.
  ///
  /// In zh, this message translates to:
  /// **'需登录'**
  String get aggregationNeedsLogin;

  /// No description provided for @aggregationForbidden.
  ///
  /// In zh, this message translates to:
  /// **'无权限'**
  String get aggregationForbidden;

  /// No description provided for @aggregationFailed.
  ///
  /// In zh, this message translates to:
  /// **'查询失败'**
  String get aggregationFailed;

  /// No description provided for @aggregationRevoked.
  ///
  /// In zh, this message translates to:
  /// **'许可已撤销'**
  String get aggregationRevoked;

  /// No description provided for @aggregationEpisodeLookup.
  ///
  /// In zh, this message translates to:
  /// **'查找此集'**
  String get aggregationEpisodeLookup;

  /// No description provided for @aggregationEpisodeMapping.
  ///
  /// In zh, this message translates to:
  /// **'核对分季与分集对应'**
  String get aggregationEpisodeMapping;

  /// No description provided for @aggregationEpisodeMappingWarning.
  ///
  /// In zh, this message translates to:
  /// **'仅季号和集号相同不能证明同一集。请先核对两份版本是否采用相同的分季和分集方式；不确定时不会提供可直接续播的来源。'**
  String get aggregationEpisodeMappingWarning;

  /// No description provided for @aggregationEpisodeMappingConfirm.
  ///
  /// In zh, this message translates to:
  /// **'已核对，按季与集对应'**
  String get aggregationEpisodeMappingConfirm;

  /// No description provided for @aggregationEpisodeConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已确认具体集（不自动跨服续播）'**
  String get aggregationEpisodeConfirmed;

  /// No description provided for @aggregationMissingEpisode.
  ///
  /// In zh, this message translates to:
  /// **'缺少目标集（非查询失败）'**
  String get aggregationMissingEpisode;

  /// No description provided for @aggregationEpisodeFailed.
  ///
  /// In zh, this message translates to:
  /// **'具体集查询失败，可重试'**
  String get aggregationEpisodeFailed;

  /// No description provided for @aggregationEpisodeUncertain.
  ///
  /// In zh, this message translates to:
  /// **'分集对应待确认，不可直接跨服续播'**
  String get aggregationEpisodeUncertain;

  /// No description provided for @deviceDetectionFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法识别设备类型，请重试或以手机模式继续。'**
  String get deviceDetectionFailed;

  /// No description provided for @appInitializationFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法初始化应用，请重试。'**
  String get appInitializationFailed;

  /// No description provided for @continueAsPhone.
  ///
  /// In zh, this message translates to:
  /// **'以手机模式继续'**
  String get continueAsPhone;

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

  /// Reload the current list or home rows. This is a manual refresh, not a failure retry.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get refresh;

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

  /// Optional HTTP User-Agent for a saved server.
  ///
  /// In zh, this message translates to:
  /// **'User-Agent'**
  String get userAgent;

  /// Hint that the server User-Agent is optional.
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

  /// Action to edit the address of one access line of a saved server.
  ///
  /// In zh, this message translates to:
  /// **'修改线路地址'**
  String get editLine;

  /// Confirm action in the line address dialog used to add or edit a line.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get lineAddressSave;

  /// Action to remove a saved Emby server from this device.
  ///
  /// In zh, this message translates to:
  /// **'删除服务器'**
  String get deleteServer;

  /// Confirmation body before removing a saved Emby server locally.
  ///
  /// In zh, this message translates to:
  /// **'删除「{name}」会同时清除本机保存的登录凭据，服务器端账号不受影响，之后可重新登录。'**
  String deleteServerConfirmMessage(String name);

  /// Destructive confirm action in the delete-server dialog.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get deleteServerConfirm;

  /// Action to change the signed-in Emby user's password.
  ///
  /// In zh, this message translates to:
  /// **'修改密码'**
  String get changePassword;

  /// Optional current-password field in the change-password dialog.
  ///
  /// In zh, this message translates to:
  /// **'旧密码'**
  String get changePasswordCurrent;

  /// Hint that an empty current password is submitted as-is.
  ///
  /// In zh, this message translates to:
  /// **'可留空，由服务器决定是否校验'**
  String get changePasswordCurrentHint;

  /// New-password field in the change-password dialog.
  ///
  /// In zh, this message translates to:
  /// **'新密码'**
  String get changePasswordNew;

  /// Repeat-new-password field in the change-password dialog.
  ///
  /// In zh, this message translates to:
  /// **'确认新密码'**
  String get changePasswordConfirm;

  /// Local check when the repeated new password differs.
  ///
  /// In zh, this message translates to:
  /// **'两次输入的新密码不一致'**
  String get changePasswordMismatch;

  /// Submit action in the change-password dialog.
  ///
  /// In zh, this message translates to:
  /// **'提交'**
  String get changePasswordSubmit;

  /// Dismiss a confirmation dialog without any change.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancelAction;

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

  /// Visible reason when switching to another access line fails and the previous line stays active.
  ///
  /// In zh, this message translates to:
  /// **'切换线路失败：{detail}'**
  String lineSwitchFailed(String detail);

  /// Server management section for the current server's item counts.
  ///
  /// In zh, this message translates to:
  /// **'库规模'**
  String get librarySize;

  /// Busy label while item counts are loading; must not show 0.
  ///
  /// In zh, this message translates to:
  /// **'正在获取库规模…'**
  String get libraryCountLoading;

  /// Movie count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'电影'**
  String get libraryCountMovie;

  /// Series count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'剧集'**
  String get libraryCountSeries;

  /// Episode count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'单集'**
  String get libraryCountEpisode;

  /// Season count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'季'**
  String get libraryTypeSeason;

  /// Trailer count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'预告片'**
  String get libraryTypeTrailer;

  /// Music album count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'音乐专辑'**
  String get libraryTypeMusicAlbum;

  /// Music artist count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'音乐艺人'**
  String get libraryTypeMusicArtist;

  /// Song count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'歌曲'**
  String get libraryTypeSong;

  /// Music video count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'音乐视频'**
  String get libraryTypeMusicVideo;

  /// Book count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'图书'**
  String get libraryTypeBook;

  /// Photo count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'照片'**
  String get libraryTypePhoto;

  /// Box set count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'合集'**
  String get libraryTypeBoxSet;

  /// Game count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'游戏'**
  String get libraryTypeGame;

  /// Audio podcast count label in the server library size section.
  ///
  /// In zh, this message translates to:
  /// **'播客'**
  String get libraryTypeAudioPodcast;

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

  /// 403 without a useful plain-text response; does not imply invalid credentials.
  ///
  /// In zh, this message translates to:
  /// **'服务器或访问防护拒绝了请求，请检查地址或线路后重试'**
  String get errorForbidden;

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
  /// **'媒体库'**
  String get libraries;

  /// Action to choose which libraries appear in the top bar and their order.
  ///
  /// In zh, this message translates to:
  /// **'自定义导航'**
  String get customizeNav;

  /// Explains the pin limit in the customize-nav dialog.
  ///
  /// In zh, this message translates to:
  /// **'最多勾选 {count} 个。顶栏放不下的会进「更多」。未勾选的不出现在导航、更多和首页媒体库。'**
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

  /// Opens the server list used to limit a search. Hidden until chosen.
  ///
  /// In zh, this message translates to:
  /// **'服务器'**
  String get searchServerFilter;

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

  /// Detail section title for links to IMDb, TMDB and other providers.
  ///
  /// In zh, this message translates to:
  /// **'外部链接'**
  String get externalLinks;

  /// Detail shelf title for similar titles when the server returns items.
  ///
  /// In zh, this message translates to:
  /// **'更多类似'**
  String get similarRow;

  /// Detail shelf title for episodes in the selected season.
  ///
  /// In zh, this message translates to:
  /// **'剧集'**
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

  /// Time left in a partially watched episode, rounded up to whole minutes.
  ///
  /// In zh, this message translates to:
  /// **'剩余 {minutes} 分钟'**
  String remainingMinutes(int minutes);

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

  /// Home hero kicker above a recently added movie title.
  ///
  /// In zh, this message translates to:
  /// **'最新电影'**
  String get heroNewMovie;

  /// Home hero kicker above a recently updated series title.
  ///
  /// In zh, this message translates to:
  /// **'最新剧集'**
  String get heroNewSeries;

  /// Accessibility label for the current home hero slide.
  ///
  /// In zh, this message translates to:
  /// **'第 {index} 项，共 {count} 项'**
  String heroItemOf(int index, int count);

  /// No description provided for @browseEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无可浏览的内容，请刷新或从媒体库开始浏览。'**
  String get browseEmpty;

  /// No description provided for @browseLoaded.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 项'**
  String browseLoaded(int count);

  /// No description provided for @pauseCarousel.
  ///
  /// In zh, this message translates to:
  /// **'暂停轮播'**
  String get pauseCarousel;

  /// No description provided for @resumeCarousel.
  ///
  /// In zh, this message translates to:
  /// **'恢复轮播'**
  String get resumeCarousel;

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

  /// No description provided for @previousEpisode.
  ///
  /// In zh, this message translates to:
  /// **'上一集'**
  String get previousEpisode;

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
  /// **'最高可用'**
  String get qualityAuto;

  /// Named transcode bitrate preset.
  ///
  /// In zh, this message translates to:
  /// **'{mbps} Mbps'**
  String qualityMbps(int mbps);

  /// Shown after sustained low download speed while playback needs more data.
  ///
  /// In zh, this message translates to:
  /// **'网络较慢，已保持当前画质；可手动切换画质'**
  String get networkSlowHint;

  /// Detail shelf of movie or episode chapters.
  ///
  /// In zh, this message translates to:
  /// **'章节'**
  String get chapters;

  /// No description provided for @phoneAlbum.
  ///
  /// In zh, this message translates to:
  /// **'相册'**
  String get phoneAlbum;

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

  /// Badge marking an external sidecar subtitle file.
  ///
  /// In zh, this message translates to:
  /// **'外挂'**
  String get subtitleMetaExternal;

  /// Badge marking an in-container subtitle stream.
  ///
  /// In zh, this message translates to:
  /// **'内嵌'**
  String get subtitleMetaEmbedded;

  /// Badge marking the server-default track.
  ///
  /// In zh, this message translates to:
  /// **'默认'**
  String get trackMetaDefault;

  /// Option count above a dense track or media source picker.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 条'**
  String trackPickerCount(int count);

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

  /// No description provided for @playerPlaying.
  ///
  /// In zh, this message translates to:
  /// **'正在播放'**
  String get playerPlaying;

  /// No description provided for @playerBuffering.
  ///
  /// In zh, this message translates to:
  /// **'正在缓冲…'**
  String get playerBuffering;

  /// Status shown while PlaybackInfo and the stream are loading.
  ///
  /// In zh, this message translates to:
  /// **'正在打开播放…'**
  String get playerLoading;

  /// Tooltip for live stream download throughput on the player chrome.
  ///
  /// In zh, this message translates to:
  /// **'实时网速'**
  String get playerNetworkSpeedTooltip;

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

  /// Settings section title and login-page entry for light/dark/system appearance.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get settingsAppearance;

  /// Short explanation under the appearance row.
  ///
  /// In zh, this message translates to:
  /// **'浅色、深色或跟随系统'**
  String get settingsAppearanceHint;

  /// Appearance choice that follows the system brightness.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get appearanceSystem;

  /// Appearance choice that forces the light theme.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get appearanceLight;

  /// Appearance choice that forces the dark theme.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get appearanceDark;

  /// Setting row label for the on-disk playback cache size limit.
  ///
  /// In zh, this message translates to:
  /// **'磁盘缓冲上限'**
  String get settingsDiskCacheLimit;

  /// Short explanation under the disk cache limit row.
  ///
  /// In zh, this message translates to:
  /// **'限制本地缓冲占用；达到上限后，随播放进度自动释放旧片段并缓存后续内容'**
  String get settingsDiskCacheLimitHint;

  /// Setting row label for hardware decoding mode.
  ///
  /// In zh, this message translates to:
  /// **'硬件解码'**
  String get settingsHardwareDecoding;

  /// Short explanation under the hardware decoding row.
  ///
  /// In zh, this message translates to:
  /// **'优先使用可用的硬件解码，失败时回退软件解码；实际启用状态以播放诊断为准'**
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

  /// Player and settings section for actual video and audio output.
  ///
  /// In zh, this message translates to:
  /// **'实际输出'**
  String get playbackOutputSection;

  /// No description provided for @playbackOutputSource.
  ///
  /// In zh, this message translates to:
  /// **'片源'**
  String get playbackOutputSource;

  /// No description provided for @playbackOutputVideo.
  ///
  /// In zh, this message translates to:
  /// **'实际视频输出'**
  String get playbackOutputVideo;

  /// No description provided for @playbackOutputAudio.
  ///
  /// In zh, this message translates to:
  /// **'实际音频输出'**
  String get playbackOutputAudio;

  /// No description provided for @playbackOutputDecode.
  ///
  /// In zh, this message translates to:
  /// **'解码路径'**
  String get playbackOutputDecode;

  /// No description provided for @playbackOutputUnknown.
  ///
  /// In zh, this message translates to:
  /// **'未知'**
  String get playbackOutputUnknown;

  /// No description provided for @playbackOutputNone.
  ///
  /// In zh, this message translates to:
  /// **'无'**
  String get playbackOutputNone;

  /// No description provided for @playbackOutputNotDolby.
  ///
  /// In zh, this message translates to:
  /// **'非杜比视界'**
  String get playbackOutputNotDolby;

  /// No description provided for @playbackOutputProfile.
  ///
  /// In zh, this message translates to:
  /// **'杜比视界 Profile {profile}'**
  String playbackOutputProfile(int profile);

  /// No description provided for @playbackOutputBaseLayer.
  ///
  /// In zh, this message translates to:
  /// **'基础层 {layer}'**
  String playbackOutputBaseLayer(String layer);

  /// No description provided for @playbackOutputBaseHdr10.
  ///
  /// In zh, this message translates to:
  /// **'HDR10'**
  String get playbackOutputBaseHdr10;

  /// No description provided for @playbackOutputBaseSdr.
  ///
  /// In zh, this message translates to:
  /// **'SDR'**
  String get playbackOutputBaseSdr;

  /// No description provided for @playbackOutputBaseHlg.
  ///
  /// In zh, this message translates to:
  /// **'HLG'**
  String get playbackOutputBaseHlg;

  /// No description provided for @playbackOutputSdr.
  ///
  /// In zh, this message translates to:
  /// **'SDR 映射'**
  String get playbackOutputSdr;

  /// No description provided for @playbackOutputHdr.
  ///
  /// In zh, this message translates to:
  /// **'HDR'**
  String get playbackOutputHdr;

  /// No description provided for @playbackOutputHdrScRgb.
  ///
  /// In zh, this message translates to:
  /// **'HDR（scRGB）'**
  String get playbackOutputHdrScRgb;

  /// No description provided for @playbackOutputHdrEdr.
  ///
  /// In zh, this message translates to:
  /// **'HDR（EDR）'**
  String get playbackOutputHdrEdr;

  /// No description provided for @playbackOutputHdrPq.
  ///
  /// In zh, this message translates to:
  /// **'HDR（PQ）'**
  String get playbackOutputHdrPq;

  /// No description provided for @playbackOutputNativeDolby.
  ///
  /// In zh, this message translates to:
  /// **'原生杜比视界'**
  String get playbackOutputNativeDolby;

  /// No description provided for @playbackOutputReconRpu.
  ///
  /// In zh, this message translates to:
  /// **'RPU'**
  String get playbackOutputReconRpu;

  /// No description provided for @playbackOutputReconFel.
  ///
  /// In zh, this message translates to:
  /// **'FEL'**
  String get playbackOutputReconFel;

  /// No description provided for @playbackOutputReconBase.
  ///
  /// In zh, this message translates to:
  /// **'基础层回退'**
  String get playbackOutputReconBase;

  /// No description provided for @playbackOutputDisplayHdrOn.
  ///
  /// In zh, this message translates to:
  /// **'显示器 HDR：开启'**
  String get playbackOutputDisplayHdrOn;

  /// No description provided for @playbackOutputDisplayHdrOff.
  ///
  /// In zh, this message translates to:
  /// **'显示器 HDR：关闭'**
  String get playbackOutputDisplayHdrOff;

  /// No description provided for @playbackOutputAudioStereo.
  ///
  /// In zh, this message translates to:
  /// **'立体声 PCM'**
  String get playbackOutputAudioStereo;

  /// No description provided for @playbackOutputAudioDownmix.
  ///
  /// In zh, this message translates to:
  /// **'立体声下混'**
  String get playbackOutputAudioDownmix;

  /// No description provided for @playbackOutputAudioChannels.
  ///
  /// In zh, this message translates to:
  /// **'{channels} 声道 PCM'**
  String playbackOutputAudioChannels(int channels);

  /// No description provided for @playbackOutputAudioPassthrough.
  ///
  /// In zh, this message translates to:
  /// **'压缩透传'**
  String get playbackOutputAudioPassthrough;

  /// No description provided for @playbackOutputAudioAtmos.
  ///
  /// In zh, this message translates to:
  /// **'Atmos 透传'**
  String get playbackOutputAudioAtmos;

  /// No description provided for @playbackOutputRequested.
  ///
  /// In zh, this message translates to:
  /// **'请求'**
  String get playbackOutputRequested;

  /// No description provided for @playbackOutputEffective.
  ///
  /// In zh, this message translates to:
  /// **'生效'**
  String get playbackOutputEffective;

  /// No description provided for @playbackOutputIdle.
  ///
  /// In zh, this message translates to:
  /// **'未在播放，实际输出未知'**
  String get playbackOutputIdle;

  /// Settings section summary for the read-only playback output status.
  ///
  /// In zh, this message translates to:
  /// **'播放时显示实际的视频解码与音频输出'**
  String get settingsOutputSummary;

  /// No description provided for @playbackOutputSpeedPcm.
  ///
  /// In zh, this message translates to:
  /// **'倍速播放时压缩透传不可用，当前输出为 PCM。'**
  String get playbackOutputSpeedPcm;

  /// No description provided for @playbackOutputBaseFallback.
  ///
  /// In zh, this message translates to:
  /// **'残差合成失败，当前是基础层回退，不是 FEL 完成。'**
  String get playbackOutputBaseFallback;

  /// No description provided for @playbackOutputProfile5MissingRpu.
  ///
  /// In zh, this message translates to:
  /// **'Profile 5 没有可用 RPU，不能按普通 HDR10 或 YUV 输出。'**
  String get playbackOutputProfile5MissingRpu;

  /// No description provided for @playbackOutputFrameRate.
  ///
  /// In zh, this message translates to:
  /// **'目标显示帧率 {rate} fps'**
  String playbackOutputFrameRate(String rate);

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

  /// Open danmaku match search from the player overlay.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
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

  /// Danmaku status showing how many comments were loaded.
  ///
  /// In zh, this message translates to:
  /// **'已加载 {count} 条'**
  String danmakuLoadedCount(int count);

  /// Small danmaku font scale step.
  ///
  /// In zh, this message translates to:
  /// **'小'**
  String get danmakuFontScaleSmall;

  /// Medium danmaku font scale step.
  ///
  /// In zh, this message translates to:
  /// **'中'**
  String get danmakuFontScaleMedium;

  /// Large danmaku font scale step.
  ///
  /// In zh, this message translates to:
  /// **'大'**
  String get danmakuFontScaleLarge;

  /// Extra-large danmaku font scale step.
  ///
  /// In zh, this message translates to:
  /// **'特大'**
  String get danmakuFontScaleExtraLarge;

  /// Slow danmaku speed step.
  ///
  /// In zh, this message translates to:
  /// **'慢'**
  String get danmakuSpeedSlow;

  /// Normal danmaku speed step.
  ///
  /// In zh, this message translates to:
  /// **'标准'**
  String get danmakuSpeedNormal;

  /// Fast danmaku speed step.
  ///
  /// In zh, this message translates to:
  /// **'快'**
  String get danmakuSpeedFast;

  /// Very fast danmaku speed step.
  ///
  /// In zh, this message translates to:
  /// **'极快'**
  String get danmakuSpeedVeryFast;

  /// Quarter-screen danmaku display area.
  ///
  /// In zh, this message translates to:
  /// **'1/4屏'**
  String get danmakuAreaQuarter;

  /// Half-screen danmaku display area.
  ///
  /// In zh, this message translates to:
  /// **'半屏'**
  String get danmakuAreaHalf;

  /// Three-quarter-screen danmaku display area.
  ///
  /// In zh, this message translates to:
  /// **'3/4屏'**
  String get danmakuAreaThreeQuarters;

  /// Full-screen danmaku display area.
  ///
  /// In zh, this message translates to:
  /// **'全屏'**
  String get danmakuAreaFull;

  /// Toggle scrolling danmaku.
  ///
  /// In zh, this message translates to:
  /// **'滚动'**
  String get danmakuTypeScroll;

  /// Toggle top fixed danmaku.
  ///
  /// In zh, this message translates to:
  /// **'顶部'**
  String get danmakuTypeTop;

  /// Toggle bottom fixed danmaku.
  ///
  /// In zh, this message translates to:
  /// **'底部'**
  String get danmakuTypeBottom;

  /// Toggle colorful danmaku; off draws all comments white.
  ///
  /// In zh, this message translates to:
  /// **'彩色'**
  String get danmakuColorful;

  /// Expands advanced danmaku display options in the player panel.
  ///
  /// In zh, this message translates to:
  /// **'高级'**
  String get danmakuAdvanced;

  /// Prevent overlapping danmaku on the same lane.
  ///
  /// In zh, this message translates to:
  /// **'防重叠'**
  String get danmakuPreventOverlap;

  /// Merge duplicate danmaku within the merge window.
  ///
  /// In zh, this message translates to:
  /// **'合并重复'**
  String get danmakuMergeDuplicates;

  /// Draw an outline around danmaku text.
  ///
  /// In zh, this message translates to:
  /// **'描边'**
  String get danmakuOutline;

  /// Whether danmaku lifetime follows playback rate.
  ///
  /// In zh, this message translates to:
  /// **'跟随倍速'**
  String get danmakuFollowPlaybackRate;

  /// Automatic on-screen danmaku density.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get danmakuDensityAuto;

  /// Sparse on-screen danmaku density.
  ///
  /// In zh, this message translates to:
  /// **'稀疏'**
  String get danmakuDensitySparse;

  /// Dense on-screen danmaku density.
  ///
  /// In zh, this message translates to:
  /// **'密集'**
  String get danmakuDensityDense;

  /// Danmaku time offset relative to playback.
  ///
  /// In zh, this message translates to:
  /// **'时间偏移'**
  String get danmakuTimeOffset;

  /// Decrease danmaku time offset by half a second.
  ///
  /// In zh, this message translates to:
  /// **'−0.5 秒'**
  String get danmakuTimeOffsetStepDown;

  /// Increase danmaku time offset by half a second.
  ///
  /// In zh, this message translates to:
  /// **'+0.5 秒'**
  String get danmakuTimeOffsetStepUp;

  /// Reset danmaku time offset to zero.
  ///
  /// In zh, this message translates to:
  /// **'归零'**
  String get danmakuTimeOffsetZero;

  /// Blocked danmaku keyword list.
  ///
  /// In zh, this message translates to:
  /// **'屏蔽关键词'**
  String get danmakuBlockedKeywords;

  /// Hint for adding a blocked danmaku keyword.
  ///
  /// In zh, this message translates to:
  /// **'输入关键词后回车'**
  String get danmakuKeywordHint;

  /// Restore danmaku display settings to defaults.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认'**
  String get danmakuRestoreDefaults;

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

  /// No description provided for @mobileMine.
  ///
  /// In zh, this message translates to:
  /// **'我的'**
  String get mobileMine;

  /// No description provided for @mobileEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无内容'**
  String get mobileEmpty;

  /// No description provided for @mobileLoadMore.
  ///
  /// In zh, this message translates to:
  /// **'加载更多'**
  String get mobileLoadMore;

  /// No description provided for @mobileAllLoaded.
  ///
  /// In zh, this message translates to:
  /// **'已显示全部内容'**
  String get mobileAllLoaded;

  /// No description provided for @mobileConnectionHint.
  ///
  /// In zh, this message translates to:
  /// **'登录你的媒体服务器，开始观看。'**
  String get mobileConnectionHint;

  /// No description provided for @mobileBackgroundPaused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停，点击播放继续'**
  String get mobileBackgroundPaused;

  /// No description provided for @mobilePreviousSession.
  ///
  /// In zh, this message translates to:
  /// **'上次播放已中断，可从详情页继续观看。'**
  String get mobilePreviousSession;

  /// No description provided for @mobileRecoveryFailed.
  ///
  /// In zh, this message translates to:
  /// **'上次播放进度同步失败，请重试。'**
  String get mobileRecoveryFailed;

  /// No description provided for @mobileRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get mobileRefresh;

  /// No description provided for @mobileBack.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get mobileBack;

  /// No description provided for @mobileTracks.
  ///
  /// In zh, this message translates to:
  /// **'音轨与字幕'**
  String get mobileTracks;

  /// No description provided for @mobilePause.
  ///
  /// In zh, this message translates to:
  /// **'暂停'**
  String get mobilePause;

  /// No description provided for @mobileForward.
  ///
  /// In zh, this message translates to:
  /// **'快进 10 秒'**
  String get mobileForward;

  /// No description provided for @mobileRewind.
  ///
  /// In zh, this message translates to:
  /// **'后退 10 秒'**
  String get mobileRewind;

  /// No description provided for @mobileSpeed.
  ///
  /// In zh, this message translates to:
  /// **'播放速度'**
  String get mobileSpeed;

  /// No description provided for @mobileLine.
  ///
  /// In zh, this message translates to:
  /// **'服务器线路'**
  String get mobileLine;

  /// TV settings pane group header for misc actions (add server, change password, logout).
  ///
  /// In zh, this message translates to:
  /// **'其他'**
  String get tvSettingsOther;

  /// 电视设置里标记当前登录的服务器
  ///
  /// In zh, this message translates to:
  /// **'当前'**
  String get tvSettingsCurrent;

  /// 电视首页行尾进入完整列表的卡片
  ///
  /// In zh, this message translates to:
  /// **'查看全部'**
  String get tvViewAll;

  /// 电视登录页左侧的一句说明
  ///
  /// In zh, this message translates to:
  /// **'连接你的媒体服务器，开始观看。Emby 账号也可以用手机扫码填写。'**
  String get tvConnectHint;

  /// 电视登录表单与手机辅助连接之间的分隔
  ///
  /// In zh, this message translates to:
  /// **'或'**
  String get tvConnectOr;

  /// 电视登录表单里的可选 UA 字段
  ///
  /// In zh, this message translates to:
  /// **'User-Agent(可选)'**
  String get tvUserAgentOptional;

  /// No description provided for @mobileAddServer.
  ///
  /// In zh, this message translates to:
  /// **'连接其他服务器'**
  String get mobileAddServer;

  /// Mine page group header for account and server rows.
  ///
  /// In zh, this message translates to:
  /// **'账户与服务器'**
  String get mobileAccountServerGroup;

  /// Mine page group header for phone chrome such as the bottom navigation.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get phoneAppearanceGroup;

  /// Switch that detaches the phone bottom navigation from the screen edge.
  ///
  /// In zh, this message translates to:
  /// **'悬浮导航栏'**
  String get phoneFloatingNav;

  /// Explains that the floating navigation sits above the page content.
  ///
  /// In zh, this message translates to:
  /// **'离开底边，页面从背后滑过'**
  String get phoneFloatingNavHint;

  /// Mine page group header for playback and danmaku settings.
  ///
  /// In zh, this message translates to:
  /// **'播放设置'**
  String get mobilePlaybackGroup;

  /// Mine page group header for the disk cache limit.
  ///
  /// In zh, this message translates to:
  /// **'缓存'**
  String get mobileCacheGroup;

  /// Mine page group header for app name and version.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get mobileAboutGroup;

  /// App version row on the phone mine page.
  ///
  /// In zh, this message translates to:
  /// **'版本 {version}'**
  String mobileVersion(String version);

  /// No description provided for @mobileSort.
  ///
  /// In zh, this message translates to:
  /// **'排序'**
  String get mobileSort;

  /// No description provided for @mobileNameSort.
  ///
  /// In zh, this message translates to:
  /// **'名称'**
  String get mobileNameSort;

  /// No description provided for @mobileDateSort.
  ///
  /// In zh, this message translates to:
  /// **'最近添加'**
  String get mobileDateSort;

  /// No description provided for @mobileWatched.
  ///
  /// In zh, this message translates to:
  /// **'已看'**
  String get mobileWatched;

  /// No description provided for @mobileUnwatched.
  ///
  /// In zh, this message translates to:
  /// **'未看'**
  String get mobileUnwatched;

  /// No description provided for @mobileMovies.
  ///
  /// In zh, this message translates to:
  /// **'电影'**
  String get mobileMovies;

  /// No description provided for @mobileSeries.
  ///
  /// In zh, this message translates to:
  /// **'剧集'**
  String get mobileSeries;

  /// Player top-bar tooltip that locks the screen against gestures.
  ///
  /// In zh, this message translates to:
  /// **'锁定屏幕'**
  String get mobileLock;

  /// Tooltip of the only visible control while the player screen is locked.
  ///
  /// In zh, this message translates to:
  /// **'解锁屏幕'**
  String get mobileUnlock;

  /// Shown when Android cannot read or apply a system brightness or volume gesture.
  ///
  /// In zh, this message translates to:
  /// **'系统调节暂不可用'**
  String get mobileGestureUnavailable;

  /// Phone player source section inside More, separate from quality.
  ///
  /// In zh, this message translates to:
  /// **'来源'**
  String get mobileSource;

  /// Visible feedback while a phone player source switch is pending.
  ///
  /// In zh, this message translates to:
  /// **'正在切换来源…'**
  String get mobileSourceSwitching;

  /// Shown before the active playback source is committed.
  ///
  /// In zh, this message translates to:
  /// **'正在确认当前来源…'**
  String get mobileSourceConfirming;

  /// Shown after a failed source switch returns to the previously playable source.
  ///
  /// In zh, this message translates to:
  /// **'来源切换失败，原来源已恢复'**
  String get mobileSourceSwitchFailed;

  /// Shown when a phone player source switch fails without restoring playback.
  ///
  /// In zh, this message translates to:
  /// **'来源切换失败，请重试'**
  String get mobileSourceSwitchFailedRetry;

  /// Hint shown briefly beside the phone player's explicit unlock button.
  ///
  /// In zh, this message translates to:
  /// **'已锁定 · 点右上角解锁'**
  String get mobileLockedHint;

  /// Player top-bar tooltip opening the bottom panel with danmaku, tracks, speed and volume.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get mobileMore;

  /// Phone player notice when a selected audio or subtitle track cannot be played. Raw playback exceptions are not shown.
  ///
  /// In zh, this message translates to:
  /// **'此轨道在当前设备上不可用'**
  String get mobileTrackUnavailable;

  /// More-panel entry that opens the danmaku settings panel.
  ///
  /// In zh, this message translates to:
  /// **'弹幕设置'**
  String get mobileDanmakuPanel;

  /// More-panel section header for the in-app volume slider and mute.
  ///
  /// In zh, this message translates to:
  /// **'应用内音量'**
  String get mobileAppVolume;

  /// Mine page group for showing, hiding and ordering phone home sections.
  ///
  /// In zh, this message translates to:
  /// **'首页区块'**
  String get phoneHomeSections;

  /// Home-screen entry and title for reordering or hiding phone home rows.
  ///
  /// In zh, this message translates to:
  /// **'编辑首页'**
  String get phoneHomeEdit;

  /// Explains that the home editor does not change the libraries tab.
  ///
  /// In zh, this message translates to:
  /// **'按住左侧手柄拖动排序。关闭的行会归到「未显示」。媒体库页仍会列出全部媒体库。'**
  String get phoneHomeEditHint;

  /// Home section label for the featured carousel.
  ///
  /// In zh, this message translates to:
  /// **'轮播图'**
  String get phoneHomeSectionBanner;

  /// Phone home section label for the next-up row.
  ///
  /// In zh, this message translates to:
  /// **'下一集'**
  String get phoneHomeSectionNextUp;

  /// Phone home section label for the latest movies row.
  ///
  /// In zh, this message translates to:
  /// **'最近电影'**
  String get phoneHomeSectionLatestMovies;

  /// Phone home section label for the latest series row.
  ///
  /// In zh, this message translates to:
  /// **'最近剧集'**
  String get phoneHomeSectionLatestSeries;

  /// Phone home section label for the library shortcut row.
  ///
  /// In zh, this message translates to:
  /// **'媒体库'**
  String get phoneHomeSectionLibraries;

  /// Phone home row and editor label for one library. The row itself is recently added items.
  ///
  /// In zh, this message translates to:
  /// **'{name}'**
  String phoneHomeLibraryLatest(String name);

  /// Heading for home rows that are currently visible.
  ///
  /// In zh, this message translates to:
  /// **'显示中'**
  String get phoneHomeShown;

  /// Heading for home rows that are turned off.
  ///
  /// In zh, this message translates to:
  /// **'未显示'**
  String get phoneHomeHidden;

  /// Tooltip for moving a phone home section earlier.
  ///
  /// In zh, this message translates to:
  /// **'上移'**
  String get phoneHomeSectionMoveUp;

  /// Tooltip for moving a phone home section later.
  ///
  /// In zh, this message translates to:
  /// **'下移'**
  String get phoneHomeSectionMoveDown;

  /// Switch tooltip for showing or hiding a phone home section.
  ///
  /// In zh, this message translates to:
  /// **'显示{name}'**
  String phoneHomeSectionVisible(String name);

  /// Player scale mode that shows the whole frame and only the black bars the aspect ratio needs.
  ///
  /// In zh, this message translates to:
  /// **'适应'**
  String get playerFit;

  /// Player scale mode that crops the frame so aspect-ratio black bars are gone.
  ///
  /// In zh, this message translates to:
  /// **'填充'**
  String get playerFill;

  /// No description provided for @settingsCategoriesHint.
  ///
  /// In zh, this message translates to:
  /// **'展开分类调整设置，再次点击可收起。修改会自动保存。'**
  String get settingsCategoriesHint;

  /// No description provided for @settingsBackToCategories.
  ///
  /// In zh, this message translates to:
  /// **'返回设置分类'**
  String get settingsBackToCategories;

  /// No description provided for @settingsPlaybackSummary.
  ///
  /// In zh, this message translates to:
  /// **'倍速、片头片尾、缓冲与硬件解码'**
  String get settingsPlaybackSummary;

  /// No description provided for @settingsDanmakuDisplaySummary.
  ///
  /// In zh, this message translates to:
  /// **'字号、不透明度、显示区域与屏蔽词'**
  String get settingsDanmakuDisplaySummary;

  /// No description provided for @settingsSkipIntro.
  ///
  /// In zh, this message translates to:
  /// **'片头提示'**
  String get settingsSkipIntro;

  /// No description provided for @settingsSkipIntroHint.
  ///
  /// In zh, this message translates to:
  /// **'手动跳过片头'**
  String get settingsSkipIntroHint;

  /// No description provided for @settingsSkipOutro.
  ///
  /// In zh, this message translates to:
  /// **'片尾提示'**
  String get settingsSkipOutro;

  /// No description provided for @settingsSkipOutroHint.
  ///
  /// In zh, this message translates to:
  /// **'片尾可跳过或进入下一集'**
  String get settingsSkipOutroHint;

  /// No description provided for @playerSkipSettings.
  ///
  /// In zh, this message translates to:
  /// **'片头与片尾'**
  String get playerSkipSettings;

  /// No description provided for @playerSettingOn.
  ///
  /// In zh, this message translates to:
  /// **'开启'**
  String get playerSettingOn;

  /// No description provided for @playerSettingOff.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get playerSettingOff;

  /// No description provided for @playerSkipSettingsSummary.
  ///
  /// In zh, this message translates to:
  /// **'片头{intro} · 片尾{outro}'**
  String playerSkipSettingsSummary(String intro, String outro);

  /// No description provided for @playerSkipSettingsSaved.
  ///
  /// In zh, this message translates to:
  /// **'自动保存，应用于所有视频'**
  String get playerSkipSettingsSaved;

  /// No description provided for @nextEpisodeHeading.
  ///
  /// In zh, this message translates to:
  /// **'接下来播放'**
  String get nextEpisodeHeading;

  /// No description provided for @nextEpisodeKeepWatching.
  ///
  /// In zh, this message translates to:
  /// **'继续看本集'**
  String get nextEpisodeKeepWatching;

  /// No description provided for @nextEpisodeStay.
  ///
  /// In zh, this message translates to:
  /// **'暂不播放'**
  String get nextEpisodeStay;

  /// No description provided for @settingsSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'设置保存失败，请重试'**
  String get settingsSaveFailed;

  /// No description provided for @playerPictureSettings.
  ///
  /// In zh, this message translates to:
  /// **'画面与音量'**
  String get playerPictureSettings;

  /// No description provided for @albumDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载原图'**
  String get albumDownload;

  /// No description provided for @albumDownloadSaved.
  ///
  /// In zh, this message translates to:
  /// **'图片已保存'**
  String get albumDownloadSaved;

  /// No description provided for @albumDownloadFailed.
  ///
  /// In zh, this message translates to:
  /// **'图片保存失败，请重试'**
  String get albumDownloadFailed;

  /// No description provided for @albumPrevious.
  ///
  /// In zh, this message translates to:
  /// **'上一张'**
  String get albumPrevious;

  /// No description provided for @albumNext.
  ///
  /// In zh, this message translates to:
  /// **'下一张'**
  String get albumNext;

  /// No description provided for @playbackDolbyVisionUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'此杜比视界版本需要专用色彩处理，当前无法播放，服务器也未提供兼容转码。请切换 HDR10 或 SDR 版本。'**
  String get playbackDolbyVisionUnsupported;

  /// No description provided for @settingsDanmakuConfiguration.
  ///
  /// In zh, this message translates to:
  /// **'弹幕配置'**
  String get settingsDanmakuConfiguration;

  /// No description provided for @settingsDanmakuConfigurationSummary.
  ///
  /// In zh, this message translates to:
  /// **'显示样式、屏蔽词与服务连接'**
  String get settingsDanmakuConfigurationSummary;

  /// No description provided for @danmakuPreview.
  ///
  /// In zh, this message translates to:
  /// **'样式预览'**
  String get danmakuPreview;

  /// No description provided for @danmakuPreviewText.
  ///
  /// In zh, this message translates to:
  /// **'一起看剧，弹幕也清晰舒适'**
  String get danmakuPreviewText;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'服务器管理'**
  String get phoneServerManagement;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'切换服务器，管理连接地址和保存的账号'**
  String get phoneServerManagementHint;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'正在使用'**
  String get phoneCurrentServer;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'管理服务器'**
  String get phoneManageServer;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'修改显示名称'**
  String get phoneRenameServer;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'显示名称'**
  String get phoneServerName;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'留空使用服务器名称'**
  String get phoneServerNameHint;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'还没有保存的服务器'**
  String get phoneEmptyServers;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'没有找到匹配的服务器'**
  String get phoneNoMatchingServers;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'操作失败，请重试'**
  String get phoneOperationFailed;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'删除正在使用的服务器后，会退出当前登录'**
  String get phoneDeleteCurrentServerHint;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'管理已保存的服务器'**
  String get phoneManageSavedServers;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get undoAction;

  /// Touch server management or desktop gesture feedback.
  ///
  /// In zh, this message translates to:
  /// **'滑动定位，松开后跳转'**
  String get phoneGestureSeek;

  /// No description provided for @phoneServerDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除「{name}」'**
  String phoneServerDeleted(String name);

  /// No description provided for @cardSeasonCount.
  ///
  /// In zh, this message translates to:
  /// **'{count}季'**
  String cardSeasonCount(int count);

  /// No description provided for @filterApply.
  ///
  /// In zh, this message translates to:
  /// **'应用筛选'**
  String get filterApply;

  /// No description provided for @filterReset.
  ///
  /// In zh, this message translates to:
  /// **'重置'**
  String get filterReset;

  /// No description provided for @filterSelectedCount.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 项'**
  String filterSelectedCount(int count);

  /// No description provided for @filterSearchOptions.
  ///
  /// In zh, this message translates to:
  /// **'查找选项'**
  String get filterSearchOptions;

  /// No description provided for @filterNoOptions.
  ///
  /// In zh, this message translates to:
  /// **'暂无可选项'**
  String get filterNoOptions;

  /// No description provided for @filterFavorite.
  ///
  /// In zh, this message translates to:
  /// **'收藏'**
  String get filterFavorite;

  /// No description provided for @filterResumable.
  ///
  /// In zh, this message translates to:
  /// **'继续观看'**
  String get filterResumable;

  /// No description provided for @filterChooseHint.
  ///
  /// In zh, this message translates to:
  /// **'同一分类可选多项，不同分类组合筛选'**
  String get filterChooseHint;

  /// No description provided for @filterBrowseTitle.
  ///
  /// In zh, this message translates to:
  /// **'筛选与排序'**
  String get filterBrowseTitle;

  /// No description provided for @filterEdit.
  ///
  /// In zh, this message translates to:
  /// **'调整'**
  String get filterEdit;

  /// No description provided for @filterSortAscending.
  ///
  /// In zh, this message translates to:
  /// **'升序'**
  String get filterSortAscending;

  /// No description provided for @filterSortDescending.
  ///
  /// In zh, this message translates to:
  /// **'降序'**
  String get filterSortDescending;

  /// No description provided for @phoneDiscover.
  ///
  /// In zh, this message translates to:
  /// **'发现好故事'**
  String get phoneDiscover;

  /// No description provided for @phoneLibraryBrowse.
  ///
  /// In zh, this message translates to:
  /// **'浏览媒体库'**
  String get phoneLibraryBrowse;

  /// No description provided for @phoneSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索电影、剧集和演员'**
  String get phoneSearchHint;

  /// No description provided for @phoneSelectedSeason.
  ///
  /// In zh, this message translates to:
  /// **'本季 {count} 集'**
  String phoneSelectedSeason(int count);

  /// No description provided for @phoneSubtitleSize.
  ///
  /// In zh, this message translates to:
  /// **'字幕大小'**
  String get phoneSubtitleSize;

  /// No description provided for @phoneSubtitleSmall.
  ///
  /// In zh, this message translates to:
  /// **'小'**
  String get phoneSubtitleSmall;

  /// No description provided for @phoneSubtitleStandard.
  ///
  /// In zh, this message translates to:
  /// **'标准'**
  String get phoneSubtitleStandard;

  /// No description provided for @phoneSubtitleLarge.
  ///
  /// In zh, this message translates to:
  /// **'大'**
  String get phoneSubtitleLarge;

  /// No description provided for @phoneSubtitleExtraLarge.
  ///
  /// In zh, this message translates to:
  /// **'特大'**
  String get phoneSubtitleExtraLarge;

  /// No description provided for @phoneSubtitleOriginal.
  ///
  /// In zh, this message translates to:
  /// **'原始 ASS 样式'**
  String get phoneSubtitleOriginal;

  /// No description provided for @phoneSubtitleOriginalHint.
  ///
  /// In zh, this message translates to:
  /// **'保留作者字号与特效；选择上方字号将关闭此项'**
  String get phoneSubtitleOriginalHint;

  /// No description provided for @phoneSubtitleUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前没有独立可调的文字字幕；图片字幕和画面内文字不支持字号调整'**
  String get phoneSubtitleUnavailable;

  /// No description provided for @phonePictureInPicture.
  ///
  /// In zh, this message translates to:
  /// **'画中画'**
  String get phonePictureInPicture;

  /// No description provided for @phonePipUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前设备或系统设置不支持画中画'**
  String get phonePipUnavailable;

  /// No description provided for @phonePipFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法进入画中画，请检查系统权限'**
  String get phonePipFailed;

  /// No description provided for @tvSectionMoveUp.
  ///
  /// In zh, this message translates to:
  /// **'上移'**
  String get tvSectionMoveUp;

  /// No description provided for @tvSectionMoveDown.
  ///
  /// In zh, this message translates to:
  /// **'下移'**
  String get tvSectionMoveDown;

  /// No description provided for @tvLanAssist.
  ///
  /// In zh, this message translates to:
  /// **'手机辅助连接'**
  String get tvLanAssist;

  /// TV LAN assist waiting section header next to the QR code.
  ///
  /// In zh, this message translates to:
  /// **'用手机扫码登录'**
  String get tvLanScanTitle;

  /// TV LAN assist instructions below the scan title.
  ///
  /// In zh, this message translates to:
  /// **'用手机相机扫码,在手机上填写服务器与账号,提交后回到电视确认即可完成登录'**
  String get tvLanScanHint;

  /// TV LAN assist header above the submitted server and account review.
  ///
  /// In zh, this message translates to:
  /// **'手机已提交,确认后登录'**
  String get tvLanPendingTitle;

  /// No description provided for @tvLanWaiting.
  ///
  /// In zh, this message translates to:
  /// **'等待手机提交'**
  String get tvLanWaiting;

  /// No description provided for @tvLanConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认连接'**
  String get tvLanConfirm;

  /// No description provided for @tvLanReject.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get tvLanReject;

  /// No description provided for @tvLanExpired.
  ///
  /// In zh, this message translates to:
  /// **'辅助连接已过期'**
  String get tvLanExpired;

  /// No description provided for @tvLanFailed.
  ///
  /// In zh, this message translates to:
  /// **'辅助连接未完成'**
  String get tvLanFailed;

  /// No description provided for @tvLanAddress.
  ///
  /// In zh, this message translates to:
  /// **'局域网地址'**
  String get tvLanAddress;

  /// No description provided for @tvLanValidUntil.
  ///
  /// In zh, this message translates to:
  /// **'本次配对有效至 {time}'**
  String tvLanValidUntil(String time);

  /// Phone series detail: heading of the season and episode section.
  ///
  /// In zh, this message translates to:
  /// **'剧集'**
  String get detailEpisodesHeader;

  /// Phone detail: heading of dates and file facts.
  ///
  /// In zh, this message translates to:
  /// **'详细信息'**
  String get detailInfo;

  /// Phone detail info row label for the premiere date.
  ///
  /// In zh, this message translates to:
  /// **'首播日期'**
  String get premiereDateLabel;

  /// Phone detail info row label for runtime.
  ///
  /// In zh, this message translates to:
  /// **'时长'**
  String get runtimeRowLabel;

  /// Phone detail info row label for the media container format.
  ///
  /// In zh, this message translates to:
  /// **'容器'**
  String get fileContainerLabel;

  /// Phone detail info row label for the media file size.
  ///
  /// In zh, this message translates to:
  /// **'文件大小'**
  String get fileSizeLabel;

  /// Phone detail info row label for the overall media bitrate.
  ///
  /// In zh, this message translates to:
  /// **'码率'**
  String get fileBitrateLabel;

  /// Phone season summary: watched episodes among the season's episodes.
  ///
  /// In zh, this message translates to:
  /// **'已看 {watched}/{total}'**
  String seasonWatchedCount(int watched, int total);

  /// Phone detail labelled action showing the item is watched; tap to mark unwatched.
  ///
  /// In zh, this message translates to:
  /// **'已看'**
  String get watchedAction;

  /// No description provided for @providerConnectTitle.
  ///
  /// In zh, this message translates to:
  /// **'连接媒体服务'**
  String get providerConnectTitle;

  /// No description provided for @providerServiceType.
  ///
  /// In zh, this message translates to:
  /// **'服务类型'**
  String get providerServiceType;

  /// No description provided for @providerConnectEntry.
  ///
  /// In zh, this message translates to:
  /// **'添加 Emby / Jellyfin / Plex'**
  String get providerConnectEntry;

  /// No description provided for @providerPlexAuthorize.
  ///
  /// In zh, this message translates to:
  /// **'使用 Plex 账号授权'**
  String get providerPlexAuthorize;

  /// No description provided for @providerQuickConnect.
  ///
  /// In zh, this message translates to:
  /// **'使用 Quick Connect'**
  String get providerQuickConnect;

  /// No description provided for @providerPlexInstructions.
  ///
  /// In zh, this message translates to:
  /// **'请在浏览器中登录 Plex 并完成授权。也可用手机打开下方地址。'**
  String get providerPlexInstructions;

  /// No description provided for @providerQuickInstructions.
  ///
  /// In zh, this message translates to:
  /// **'在已登录的 Jellyfin 应用中打开 Quick Connect，输入下方代码。'**
  String get providerQuickInstructions;

  /// No description provided for @providerOpenBrowser.
  ///
  /// In zh, this message translates to:
  /// **'打开浏览器'**
  String get providerOpenBrowser;

  /// No description provided for @providerWaitingAuthorization.
  ///
  /// In zh, this message translates to:
  /// **'等待授权…'**
  String get providerWaitingAuthorization;

  /// No description provided for @providerDiscovering.
  ///
  /// In zh, this message translates to:
  /// **'正在发现服务器…'**
  String get providerDiscovering;

  /// No description provided for @providerRestart.
  ///
  /// In zh, this message translates to:
  /// **'重新授权'**
  String get providerRestart;

  /// No description provided for @providerChooseHome.
  ///
  /// In zh, this message translates to:
  /// **'Plex Home 用户'**
  String get providerChooseHome;

  /// No description provided for @providerHomePin.
  ///
  /// In zh, this message translates to:
  /// **'Plex Home PIN'**
  String get providerHomePin;

  /// No description provided for @providerHomePinHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入 Plex Home 用户的 PIN，不是灯川私密 PIN。'**
  String get providerHomePinHint;

  /// No description provided for @providerSwitchHome.
  ///
  /// In zh, this message translates to:
  /// **'切换用户并重新发现服务器'**
  String get providerSwitchHome;

  /// No description provided for @providerChooseResource.
  ///
  /// In zh, this message translates to:
  /// **'选择服务器与连接线路'**
  String get providerChooseResource;

  /// No description provided for @providerNoResources.
  ///
  /// In zh, this message translates to:
  /// **'当前用户没有可用服务器，请选择 Home 用户或重新授权。'**
  String get providerNoResources;

  /// No description provided for @providerLocal.
  ///
  /// In zh, this message translates to:
  /// **'本地'**
  String get providerLocal;

  /// No description provided for @providerRemote.
  ///
  /// In zh, this message translates to:
  /// **'远程'**
  String get providerRemote;

  /// No description provided for @providerRelay.
  ///
  /// In zh, this message translates to:
  /// **'中继（带宽受限）'**
  String get providerRelay;

  /// No description provided for @providerChooseLibraries.
  ///
  /// In zh, this message translates to:
  /// **'已连接。勾选参与聚合的影视库；不勾选仍可单独浏览此服务。'**
  String get providerChooseLibraries;

  /// No description provided for @providerNoLibraries.
  ///
  /// In zh, this message translates to:
  /// **'没有发现可访问的影视库。可重试或保留空范围。'**
  String get providerNoLibraries;

  /// No description provided for @providerFinish.
  ///
  /// In zh, this message translates to:
  /// **'保存并完成'**
  String get providerFinish;

  /// No description provided for @providerCredentialsRejected.
  ///
  /// In zh, this message translates to:
  /// **'账号、密码或 Home PIN 不正确，请重试。'**
  String get providerCredentialsRejected;

  /// No description provided for @providerPermissionDenied.
  ///
  /// In zh, this message translates to:
  /// **'当前账号无权访问，请检查共享权限或重新授权。'**
  String get providerPermissionDenied;

  /// No description provided for @providerRateLimited.
  ///
  /// In zh, this message translates to:
  /// **'服务暂时限制请求，请稍后重试。'**
  String get providerRateLimited;

  /// No description provided for @providerAuthorizationExpired.
  ///
  /// In zh, this message translates to:
  /// **'授权已过期、被拒绝或取消，请重新授权。'**
  String get providerAuthorizationExpired;

  /// No description provided for @providerSignatureFailure.
  ///
  /// In zh, this message translates to:
  /// **'授权签名或设备时间校验失败，请校准系统时间后重试。'**
  String get providerSignatureFailure;

  /// No description provided for @providerQuickUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'服务器未开放 Quick Connect，请使用密码登录。'**
  String get providerQuickUnavailable;

  /// No description provided for @providerCertificateFailure.
  ///
  /// In zh, this message translates to:
  /// **'服务器证书校验失败，请检查服务器配置。'**
  String get providerCertificateFailure;

  /// No description provided for @providerConnectionFailure.
  ///
  /// In zh, this message translates to:
  /// **'连接未完成，请检查地址和网络后重试。'**
  String get providerConnectionFailure;

  /// No description provided for @providerBrowserFailure.
  ///
  /// In zh, this message translates to:
  /// **'无法打开浏览器，请在其它设备打开授权地址。'**
  String get providerBrowserFailure;

  /// No description provided for @providerHomeManage.
  ///
  /// In zh, this message translates to:
  /// **'切换 Plex Home 用户'**
  String get providerHomeManage;

  /// No description provided for @providerServerOrder.
  ///
  /// In zh, this message translates to:
  /// **'此列表按服务器提供的顺序显示'**
  String get providerServerOrder;

  /// No description provided for @providerOwned.
  ///
  /// In zh, this message translates to:
  /// **'自有服务器'**
  String get providerOwned;

  /// No description provided for @providerShared.
  ///
  /// In zh, this message translates to:
  /// **'共享服务器'**
  String get providerShared;

  /// No description provided for @providerAccountManage.
  ///
  /// In zh, this message translates to:
  /// **'Plex 账号设置'**
  String get providerAccountManage;

  /// No description provided for @providerAccountInstructions.
  ///
  /// In zh, this message translates to:
  /// **'Plex 账号与密码在官方网页中管理。请打开浏览器，或在手机上访问下方地址。'**
  String get providerAccountInstructions;

  /// No description provided for @loginWelcomeTitle.
  ///
  /// In zh, this message translates to:
  /// **'连接你的媒体库'**
  String get loginWelcomeTitle;

  /// No description provided for @loginWelcomeSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'登录 Emby、Jellyfin 或 Plex 服务器，在这台设备上继续观看。'**
  String get loginWelcomeSubtitle;

  /// No description provided for @loginServiceLabel.
  ///
  /// In zh, this message translates to:
  /// **'服务类型'**
  String get loginServiceLabel;

  /// No description provided for @loginEmbyHint.
  ///
  /// In zh, this message translates to:
  /// **'填写服务器地址与账号密码登录 Emby。'**
  String get loginEmbyHint;

  /// No description provided for @loginJellyfinHint.
  ///
  /// In zh, this message translates to:
  /// **'使用账号密码登录，或在已登录的设备上用 Quick Connect 授权。'**
  String get loginJellyfinHint;

  /// No description provided for @loginPlexHint.
  ///
  /// In zh, this message translates to:
  /// **'使用 Plex 账号授权，自动发现你可以访问的服务器。'**
  String get loginPlexHint;

  /// No description provided for @loginAdvanced.
  ///
  /// In zh, this message translates to:
  /// **'高级选项'**
  String get loginAdvanced;

  /// No description provided for @loginPlexTitle.
  ///
  /// In zh, this message translates to:
  /// **'使用 Plex 账号登录'**
  String get loginPlexTitle;

  /// No description provided for @loginPlexStep1.
  ///
  /// In zh, this message translates to:
  /// **'点击下方按钮，在浏览器中打开 plex.tv 授权页'**
  String get loginPlexStep1;

  /// No description provided for @loginPlexStep2.
  ///
  /// In zh, this message translates to:
  /// **'登录 Plex 账号，允许灯川访问'**
  String get loginPlexStep2;

  /// No description provided for @loginPlexStep3.
  ///
  /// In zh, this message translates to:
  /// **'回到这里，选择服务器与连接线路'**
  String get loginPlexStep3;

  /// No description provided for @loginQuickConnectHint.
  ///
  /// In zh, this message translates to:
  /// **'无需输入密码'**
  String get loginQuickConnectHint;

  /// No description provided for @loginSavedServersHint.
  ///
  /// In zh, this message translates to:
  /// **'选择一台服务器，自动填入地址与账号'**
  String get loginSavedServersHint;

  /// No description provided for @loginServerCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 台服务器'**
  String loginServerCount(int count);

  /// No description provided for @providerCopyCode.
  ///
  /// In zh, this message translates to:
  /// **'复制代码'**
  String get providerCopyCode;

  /// No description provided for @providerCodeCopied.
  ///
  /// In zh, this message translates to:
  /// **'代码已复制'**
  String get providerCodeCopied;

  /// No description provided for @providerAuthorizationCodeLabel.
  ///
  /// In zh, this message translates to:
  /// **'授权代码'**
  String get providerAuthorizationCodeLabel;

  /// No description provided for @providerSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get providerSelectAll;

  /// No description provided for @providerSelectNone.
  ///
  /// In zh, this message translates to:
  /// **'全不选'**
  String get providerSelectNone;

  /// No description provided for @playerShowRemaining.
  ///
  /// In zh, this message translates to:
  /// **'显示剩余时间'**
  String get playerShowRemaining;

  /// No description provided for @playerShowDuration.
  ///
  /// In zh, this message translates to:
  /// **'显示总时长'**
  String get playerShowDuration;

  /// No description provided for @playerRemainingClock.
  ///
  /// In zh, this message translates to:
  /// **'-{time}'**
  String playerRemainingClock(String time);

  /// No description provided for @playerEndsAt.
  ///
  /// In zh, this message translates to:
  /// **'{time} 结束'**
  String playerEndsAt(String time);

  /// No description provided for @phoneLibrariesMine.
  ///
  /// In zh, this message translates to:
  /// **'我的媒体库'**
  String get phoneLibrariesMine;

  /// No description provided for @phoneLibrariesShortcuts.
  ///
  /// In zh, this message translates to:
  /// **'快速入口'**
  String get phoneLibrariesShortcuts;

  /// No description provided for @phoneShortcutLatestMovies.
  ///
  /// In zh, this message translates to:
  /// **'最新电影'**
  String get phoneShortcutLatestMovies;

  /// No description provided for @phoneShortcutLatestSeries.
  ///
  /// In zh, this message translates to:
  /// **'最新剧集'**
  String get phoneShortcutLatestSeries;

  /// No description provided for @phoneLibraryCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个媒体库'**
  String phoneLibraryCount(int count);

  /// No description provided for @phoneSearchRecent.
  ///
  /// In zh, this message translates to:
  /// **'最近搜索'**
  String get phoneSearchRecent;

  /// No description provided for @phoneSearchClearRecent.
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get phoneSearchClearRecent;

  /// No description provided for @phoneSearchIdleTitle.
  ///
  /// In zh, this message translates to:
  /// **'想看点什么？'**
  String get phoneSearchIdleTitle;

  /// No description provided for @phoneSearchResultCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个结果'**
  String phoneSearchResultCount(int count);

  /// No description provided for @phoneFavorite.
  ///
  /// In zh, this message translates to:
  /// **'收藏'**
  String get phoneFavorite;

  /// No description provided for @phoneFavorited.
  ///
  /// In zh, this message translates to:
  /// **'已收藏'**
  String get phoneFavorited;

  /// No description provided for @phoneFavoriteAdded.
  ///
  /// In zh, this message translates to:
  /// **'已加入收藏'**
  String get phoneFavoriteAdded;

  /// No description provided for @phoneFavoriteRemoved.
  ///
  /// In zh, this message translates to:
  /// **'已取消收藏'**
  String get phoneFavoriteRemoved;

  /// No description provided for @phoneFavoriteFailed.
  ///
  /// In zh, this message translates to:
  /// **'收藏没有保存，请稍后再试'**
  String get phoneFavoriteFailed;

  /// Primary subtitle slot label.
  ///
  /// In zh, this message translates to:
  /// **'主字幕'**
  String get subtitleTrackPrimary;

  /// Secondary subtitle slot label.
  ///
  /// In zh, this message translates to:
  /// **'次字幕'**
  String get subtitleTrackSecondary;

  /// Entry for importing a session-local subtitle file.
  ///
  /// In zh, this message translates to:
  /// **'导入本地字幕…'**
  String get subtitleImportLocal;

  /// Progress note while a subtitle import is running.
  ///
  /// In zh, this message translates to:
  /// **'正在导入字幕…'**
  String get subtitleImportRunning;

  /// Import finished as a duplicate of an existing candidate.
  ///
  /// In zh, this message translates to:
  /// **'相同内容的字幕已在候选列表中'**
  String get subtitleImportDuplicate;

  /// Import rejected because content validation failed.
  ///
  /// In zh, this message translates to:
  /// **'不是有效的 SRT/ASS/SSA/VTT UTF-8 字幕文件'**
  String get subtitleImportInvalid;

  /// Import rejected because the file exceeds the single-file limit.
  ///
  /// In zh, this message translates to:
  /// **'字幕文件超过单文件大小限制'**
  String get subtitleImportTooLarge;

  /// Import rejected because the session total size limit is reached.
  ///
  /// In zh, this message translates to:
  /// **'会话内字幕文件总大小已达上限'**
  String get subtitleImportSessionLimit;

  /// Import failed while reading or copying the file.
  ///
  /// In zh, this message translates to:
  /// **'字幕文件无法读取'**
  String get subtitleImportUnreadable;

  /// No documents provider is available, common on Android TV.
  ///
  /// In zh, this message translates to:
  /// **'此设备没有可用的文件选择器'**
  String get subtitleImportPickerUnavailable;

  /// A source cannot occupy both subtitle slots at once.
  ///
  /// In zh, this message translates to:
  /// **'该来源已在另一字幕槽位使用'**
  String get subtitleSlotOccupied;

  /// Burned-in transcode subtitles cannot fill the secondary slot.
  ///
  /// In zh, this message translates to:
  /// **'烧录字幕无法作为可独立关闭的次字幕'**
  String get subtitleBurnInSecondary;

  /// Badge marking a session-imported local subtitle file.
  ///
  /// In zh, this message translates to:
  /// **'本地导入'**
  String get subtitleMetaImported;

  /// Server management / connect pages: entry that imports a Hills or Rodel backup file.
  ///
  /// In zh, this message translates to:
  /// **'导入备份'**
  String get backupImportEntry;

  /// Native file picker dialog title for backup import.
  ///
  /// In zh, this message translates to:
  /// **'选择备份文件'**
  String get backupImportPickerTitle;

  /// Loading dialog shown while a backup is parsed and committed.
  ///
  /// In zh, this message translates to:
  /// **'正在读取备份…'**
  String get backupImportWorking;

  /// Result panel title after a backup was committed.
  ///
  /// In zh, this message translates to:
  /// **'备份导入结果'**
  String get backupImportResultTitle;

  /// Result panel title when the backup could not be read or parsed.
  ///
  /// In zh, this message translates to:
  /// **'备份导入未完成'**
  String get backupImportFailureTitle;

  /// Backup import result panel close action.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get backupImportClose;

  /// Result row: how many servers were added.
  ///
  /// In zh, this message translates to:
  /// **'新增 {count} 台'**
  String backupImportAddedCount(int count);

  /// Result row: added accounts that carry credentials and can be verified on connect.
  ///
  /// In zh, this message translates to:
  /// **'已带凭据 {count} 个'**
  String backupImportCredentialsReady(int count);

  /// Result row: added accounts without credentials that stay pending login.
  ///
  /// In zh, this message translates to:
  /// **'待登录 {count} 个'**
  String backupImportPendingLogin(int count);

  /// Result row: records equal to an already saved account and line.
  ///
  /// In zh, this message translates to:
  /// **'重复跳过 {count} 台'**
  String backupImportDuplicateCount(int count);

  /// Records with unsupported service types that were not migrated.
  ///
  /// In zh, this message translates to:
  /// **'不支持的服务类型 {count} 条'**
  String backupImportNonTargetCount(int count);

  /// Result row: records that failed to parse or commit.
  ///
  /// In zh, this message translates to:
  /// **'失败 {count} 条'**
  String backupImportFailedCount(int count);

  /// Result row: private-region records skipped because the private area is locked.
  ///
  /// In zh, this message translates to:
  /// **'私密区域未解锁，跳过 {count} 条'**
  String backupImportPrivateSkippedCount(int count);

  /// Failure shown when the device has no documents provider.
  ///
  /// In zh, this message translates to:
  /// **'此设备没有可用的文件选择器，无法选择备份文件'**
  String get backupImportPickerUnavailable;

  /// Failure shown for oversized backup files.
  ///
  /// In zh, this message translates to:
  /// **'备份文件超过大小限制'**
  String get backupImportTooLarge;

  /// Failure shown when the picked file cannot be read.
  ///
  /// In zh, this message translates to:
  /// **'备份文件无法读取'**
  String get backupImportUnreadable;

  /// Failure for an unrecognized container.
  ///
  /// In zh, this message translates to:
  /// **'无法识别的备份格式'**
  String get backupImportUnrecognized;

  /// Failure for a damaged container.
  ///
  /// In zh, this message translates to:
  /// **'备份文件已损坏'**
  String get backupImportCorrupt;

  /// Failure for a backup version the parser does not support.
  ///
  /// In zh, this message translates to:
  /// **'暂不支持该备份版本'**
  String get backupImportUnsupportedVersion;

  /// Honest failure when the decryption key for an encrypted backup is not provisioned.
  ///
  /// In zh, this message translates to:
  /// **'缺少解密密钥，未读取加密内容'**
  String get backupImportKeyUnavailable;

  /// Failure when the payload cannot be decrypted with the provided key.
  ///
  /// In zh, this message translates to:
  /// **'备份内容无法解密'**
  String get backupImportUndecryptable;

  /// Parse-level failure reason shown under the failed row.
  ///
  /// In zh, this message translates to:
  /// **'部分记录缺少名称或线路，未导入'**
  String get backupImportReasonMissingFields;

  /// Commit failure reason: invalid configuration.
  ///
  /// In zh, this message translates to:
  /// **'记录配置无效，未导入'**
  String get backupImportReasonInvalid;

  /// Commit failure reason: connection semantics the app cannot express.
  ///
  /// In zh, this message translates to:
  /// **'包含无法表达的连接选项，未导入'**
  String get backupImportReasonUnsupportedOptions;

  /// Commit failure reason: access or region changed during import.
  ///
  /// In zh, this message translates to:
  /// **'导入期间权限或区域已变更，未导入'**
  String get backupImportReasonAccessRevoked;

  /// Commit failure reason: persistence failed.
  ///
  /// In zh, this message translates to:
  /// **'保存失败，未导入'**
  String get backupImportReasonPersistence;

  /// Commit failure reason: rollback failed so remaining records were stopped.
  ///
  /// In zh, this message translates to:
  /// **'存储状态不确定，已停止后续写入'**
  String get backupImportReasonRollback;

  /// No description provided for @updateCheck.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get updateCheck;

  /// No description provided for @updateChecking.
  ///
  /// In zh, this message translates to:
  /// **'正在检查更新…'**
  String get updateChecking;

  /// No description provided for @updateCheckFailed.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法检查更新，请检查网络后重试。'**
  String get updateCheckFailed;

  /// No description provided for @updateAvailable.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本 {version}'**
  String updateAvailable(String version);

  /// No description provided for @updateCurrent.
  ///
  /// In zh, this message translates to:
  /// **'当前已是最新版本'**
  String get updateCurrent;

  /// No description provided for @updateOpenRelease.
  ///
  /// In zh, this message translates to:
  /// **'打开 Release 页'**
  String get updateOpenRelease;

  /// No description provided for @updateNotes.
  ///
  /// In zh, this message translates to:
  /// **'更新内容'**
  String get updateNotes;

  /// No description provided for @updateOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开 Release 页，请确认已安装浏览器后重试。'**
  String get updateOpenFailed;

  /// No description provided for @updateDownload.
  ///
  /// In zh, this message translates to:
  /// **'应用内下载'**
  String get updateDownload;

  /// No description provided for @updateCancelDownload.
  ///
  /// In zh, this message translates to:
  /// **'取消下载'**
  String get updateCancelDownload;

  /// No description provided for @updateNoPackage.
  ///
  /// In zh, this message translates to:
  /// **'没有适用于当前系统及架构的安装包。可打开 Release 页查看。'**
  String get updateNoPackage;

  /// No description provided for @updateTimeout.
  ///
  /// In zh, this message translates to:
  /// **'检查更新超时，请稍后重试。'**
  String get updateTimeout;

  /// No description provided for @updateRateLimited.
  ///
  /// In zh, this message translates to:
  /// **'更新服务请求过于频繁，请稍后重试。'**
  String get updateRateLimited;

  /// No description provided for @updateNoRelease.
  ///
  /// In zh, this message translates to:
  /// **'暂时没有可用的正式发布，请稍后重试。'**
  String get updateNoRelease;

  /// No description provided for @updateInvalidResponse.
  ///
  /// In zh, this message translates to:
  /// **'更新信息无效，无法确认是否有新版。请稍后重试。'**
  String get updateInvalidResponse;

  /// No description provided for @updatePackageVersion.
  ///
  /// In zh, this message translates to:
  /// **'安装包版本 {version}'**
  String updatePackageVersion(String version);

  /// No description provided for @updateDownloadingUnknown.
  ///
  /// In zh, this message translates to:
  /// **'正在下载 · 已下载 {received}'**
  String updateDownloadingUnknown(String received);

  /// No description provided for @updateDownloading.
  ///
  /// In zh, this message translates to:
  /// **'正在下载 {percent}% · {received} / {total}'**
  String updateDownloading(String received, String total, int percent);

  /// No description provided for @updateVerifying.
  ///
  /// In zh, this message translates to:
  /// **'正在校验安装包…'**
  String get updateVerifying;

  /// No description provided for @updateReady.
  ///
  /// In zh, this message translates to:
  /// **'安装包已通过完整性校验，可继续安装。'**
  String get updateReady;

  /// No description provided for @updateCancelled.
  ///
  /// In zh, this message translates to:
  /// **'下载已取消，可重新下载。'**
  String get updateCancelled;

  /// No description provided for @updateChecksumFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法通过安装包完整性校验，已禁止安装。请重新下载或打开 Release 页。'**
  String get updateChecksumFailed;

  /// No description provided for @updateVerificationUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'无法获取校验文件，无法完成安装包完整性校验，已禁止安装。请重试或打开 Release 页。'**
  String get updateVerificationUnavailable;

  /// No description provided for @updateDiskFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法保存安装包，请检查剩余存储空间及目录权限后重试。'**
  String get updateDiskFailed;

  /// No description provided for @updateDownloadTimeout.
  ///
  /// In zh, this message translates to:
  /// **'下载超时，请重试或打开 Release 页。'**
  String get updateDownloadTimeout;

  /// No description provided for @updateUnsafePackage.
  ///
  /// In zh, this message translates to:
  /// **'安装包来源不符合官方发布规则，已停止下载。可打开 Release 页。'**
  String get updateUnsafePackage;

  /// No description provided for @updateDownloadFailed.
  ///
  /// In zh, this message translates to:
  /// **'下载失败，请检查网络后重试，或打开 Release 页。'**
  String get updateDownloadFailed;

  /// No description provided for @updateInstall.
  ///
  /// In zh, this message translates to:
  /// **'继续安装'**
  String get updateInstall;

  /// No description provided for @updateInstalling.
  ///
  /// In zh, this message translates to:
  /// **'正在交给系统处理…'**
  String get updateInstalling;

  /// No description provided for @updateWindowsGuide.
  ///
  /// In zh, this message translates to:
  /// **'继续后将打开 Windows 安装程序，请按系统提示确认。如需退出应用，请先结束播放，再通过窗口关闭按钮退出后继续安装。'**
  String get updateWindowsGuide;

  /// No description provided for @updateMacGuide.
  ///
  /// In zh, this message translates to:
  /// **'继续后请选择安装包保存位置，打开 DMG，将应用拖入“应用程序”并确认替换。如需退出，请先结束播放并正常关闭应用。'**
  String get updateMacGuide;

  /// No description provided for @updateLinuxGuide.
  ///
  /// In zh, this message translates to:
  /// **'继续后将打开 DEB 安装包，请按软件安装器提示操作。若未能打开，可在文件管理器中找到下方本地文件，使用系统的软件安装器安装。'**
  String get updateLinuxGuide;

  /// No description provided for @updateAndroidGuide.
  ///
  /// In zh, this message translates to:
  /// **'继续后将打开系统安装页面，请按提示完成。如需允许安装来源，请先授权，再返回此处重试安装。'**
  String get updateAndroidGuide;

  /// No description provided for @updateFinishPlayback.
  ///
  /// In zh, this message translates to:
  /// **'请先结束并退出播放，再继续安装更新。'**
  String get updateFinishPlayback;

  /// No description provided for @updateHandedOff.
  ///
  /// In zh, this message translates to:
  /// **'已交给系统安装流程。请按系统提示完成，重新打开应用后确认版本。'**
  String get updateHandedOff;

  /// No description provided for @updatePermissionRequired.
  ///
  /// In zh, this message translates to:
  /// **'尚未允许此应用安装更新，请打开来源授权设置。'**
  String get updatePermissionRequired;

  /// No description provided for @updateAllowSource.
  ///
  /// In zh, this message translates to:
  /// **'打开来源授权设置'**
  String get updateAllowSource;

  /// No description provided for @updatePermissionOpened.
  ///
  /// In zh, this message translates to:
  /// **'已打开来源授权设置。允许后返回此处，再点击“继续安装”；尚未开始安装。'**
  String get updatePermissionOpened;

  /// No description provided for @updatePermissionDenied.
  ///
  /// In zh, this message translates to:
  /// **'系统未授予所需权限。请确认权限后重试。'**
  String get updatePermissionDenied;

  /// No description provided for @updateInstallCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消系统操作，尚未确认更新完成。可再次尝试。'**
  String get updateInstallCancelled;

  /// No description provided for @updateIncompatible.
  ///
  /// In zh, this message translates to:
  /// **'安装包与当前应用身份、签名或版本不兼容，无法安装。可打开 Release 页查看。'**
  String get updateIncompatible;

  /// No description provided for @updateInstallFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法启动系统安装流程。请按平台指引处理或重试，也可打开 Release 页。'**
  String get updateInstallFailed;

  /// No description provided for @updateLocalPackage.
  ///
  /// In zh, this message translates to:
  /// **'本地安装包：{path}'**
  String updateLocalPackage(String path);

  /// No description provided for @updateReminderTitle.
  ///
  /// In zh, this message translates to:
  /// **'应用更新'**
  String get updateReminderTitle;

  /// No description provided for @updateReminderSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'发现可用更新，可直接在应用内下载校验并安装'**
  String get updateReminderSubtitle;

  /// No description provided for @updateVersionTransition.
  ///
  /// In zh, this message translates to:
  /// **'当前 v{current} → 最新 v{target}'**
  String updateVersionTransition(String current, String target);

  /// No description provided for @updateCurrentBadge.
  ///
  /// In zh, this message translates to:
  /// **'已是最新'**
  String get updateCurrentBadge;

  /// No description provided for @updateNewBadge.
  ///
  /// In zh, this message translates to:
  /// **'可更新'**
  String get updateNewBadge;

  /// No description provided for @updateIgnoreVersion.
  ///
  /// In zh, this message translates to:
  /// **'此版本不再提醒'**
  String get updateIgnoreVersion;

  /// No description provided for @updateUnignoreVersion.
  ///
  /// In zh, this message translates to:
  /// **'恢复此版本提醒'**
  String get updateUnignoreVersion;

  /// No description provided for @updateIgnoredBadge.
  ///
  /// In zh, this message translates to:
  /// **'已忽略 v{version} 提醒'**
  String updateIgnoredBadge(String version);

  /// No description provided for @updateDisableReminder.
  ///
  /// In zh, this message translates to:
  /// **'不再自动提醒'**
  String get updateDisableReminder;

  /// No description provided for @updateAutoReminderTitle.
  ///
  /// In zh, this message translates to:
  /// **'启动时自动提醒更新'**
  String get updateAutoReminderTitle;

  /// No description provided for @updateAutoReminderSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本时自动弹窗提醒，关闭后仍可在此处手动检查'**
  String get updateAutoReminderSubtitle;

  /// No description provided for @updateLater.
  ///
  /// In zh, this message translates to:
  /// **'稍后处理'**
  String get updateLater;

  /// Settings section title for WebDAV backup and restore.
  ///
  /// In zh, this message translates to:
  /// **'备份与同步'**
  String get settingsWebDavSection;

  /// Summary of the WebDAV backup section.
  ///
  /// In zh, this message translates to:
  /// **'手动备份完整配置到自备 WebDAV，换机可一键恢复'**
  String get settingsWebDavSectionSummary;

  /// Setting row label for the WebDAV server address.
  ///
  /// In zh, this message translates to:
  /// **'服务器地址'**
  String get settingsWebDavAddress;

  /// Placeholder for the WebDAV server address.
  ///
  /// In zh, this message translates to:
  /// **'例如 https://dav.example.com:5006'**
  String get settingsWebDavAddressHint;

  /// Setting row label for the WebDAV account name.
  ///
  /// In zh, this message translates to:
  /// **'账号'**
  String get settingsWebDavUsername;

  /// Setting row label for the WebDAV password.
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get settingsWebDavPassword;

  /// Tooltip to reveal the WebDAV password.
  ///
  /// In zh, this message translates to:
  /// **'显示密码'**
  String get settingsWebDavPasswordShow;

  /// Tooltip to hide the WebDAV password.
  ///
  /// In zh, this message translates to:
  /// **'隐藏密码'**
  String get settingsWebDavPasswordHide;

  /// Setting row label for the remote WebDAV backup directory.
  ///
  /// In zh, this message translates to:
  /// **'备份目录'**
  String get settingsWebDavDirectory;

  /// Hint that an empty directory falls back to the WebDAV root.
  ///
  /// In zh, this message translates to:
  /// **'远端存放备份文件的目录，留空使用根目录'**
  String get settingsWebDavDirectoryHint;

  /// Button that probes the configured WebDAV server.
  ///
  /// In zh, this message translates to:
  /// **'测试连接'**
  String get settingsWebDavTestConnection;

  /// Notice when the WebDAV connection test succeeds.
  ///
  /// In zh, this message translates to:
  /// **'连接成功'**
  String get settingsWebDavConnectionOk;

  /// Notice when the WebDAV server rejects the credentials.
  ///
  /// In zh, this message translates to:
  /// **'账号或密码错误'**
  String get settingsWebDavCredentialError;

  /// Notice when the WebDAV directory does not exist.
  ///
  /// In zh, this message translates to:
  /// **'备份目录不存在，请先创建或修改目录'**
  String get settingsWebDavDirectoryMissing;

  /// Notice when the WebDAV server returns an unexpected status.
  ///
  /// In zh, this message translates to:
  /// **'服务器返回错误（HTTP {status}）'**
  String settingsWebDavHttpError(int status);

  /// Notice when the WebDAV server cannot be reached.
  ///
  /// In zh, this message translates to:
  /// **'无法连接服务器，请检查地址与网络'**
  String get settingsWebDavUnreachable;

  /// Button that uploads a full local backup to WebDAV.
  ///
  /// In zh, this message translates to:
  /// **'立即备份'**
  String get settingsWebDavBackup;

  /// Notice when the WebDAV backup upload succeeds.
  ///
  /// In zh, this message translates to:
  /// **'备份完成 · {time}'**
  String settingsWebDavBackupDone(String time);

  /// Notice when a local configuration file cannot be parsed.
  ///
  /// In zh, this message translates to:
  /// **'本地配置文件损坏，本次操作已取消'**
  String get settingsWebDavLocalConfigCorrupt;

  /// Notice for an unexpected WebDAV backup failure.
  ///
  /// In zh, this message translates to:
  /// **'备份失败，请重试'**
  String get settingsWebDavBackupFailed;

  /// Button that downloads and applies the WebDAV backup.
  ///
  /// In zh, this message translates to:
  /// **'从备份恢复'**
  String get settingsWebDavRestore;

  /// Notice when the WebDAV backup has been applied.
  ///
  /// In zh, this message translates to:
  /// **'已恢复'**
  String get settingsWebDavRestored;

  /// Notice when the WebDAV server has no backup file.
  ///
  /// In zh, this message translates to:
  /// **'服务器上还没有备份文件'**
  String get settingsWebDavNoBackup;

  /// Notice when the downloaded backup fails validation.
  ///
  /// In zh, this message translates to:
  /// **'备份文件校验未通过，本地数据未改动'**
  String get settingsWebDavRestoreRejected;

  /// Notice for an unexpected WebDAV restore failure.
  ///
  /// In zh, this message translates to:
  /// **'恢复失败，请重试'**
  String get settingsWebDavRestoreFailed;

  /// Notice when an action runs without a WebDAV address.
  ///
  /// In zh, this message translates to:
  /// **'请先填写 WebDAV 服务器地址'**
  String get settingsWebDavNotConfigured;

  /// Notice when the WebDAV configuration cannot be saved.
  ///
  /// In zh, this message translates to:
  /// **'配置保存失败，请重试'**
  String get settingsWebDavSaveFailed;
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
