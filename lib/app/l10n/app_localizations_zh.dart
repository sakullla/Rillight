// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get sourceManagement => '服务与范围管理';

  @override
  String get privateSetPin => '设置 PIN';

  @override
  String get privatePin => 'PIN（4–12 位数字）';

  @override
  String get privateConfirmPin => '再次输入 PIN';

  @override
  String get privateUnlock => '解锁';

  @override
  String get privateLock => '立即锁定';

  @override
  String get privatePinFailure => 'PIN 错误或操作失败，请稍后重试';

  @override
  String get privateRateLimited => '尝试过于频繁，请等待重试时间后再解锁';

  @override
  String get sourceParticipates => '参与聚合';

  @override
  String get sourceDiscoverLibraries => '读取媒体库（不自动选择）';

  @override
  String get sourceScopeUnknown => '范围未知；请读取并明确选择媒体库';

  @override
  String get sourceIndependentLogin => '独立账号登录';

  @override
  String get sourceManualCheck => '手动检查';

  @override
  String get sourceMovePrivate => '移入私密区域';

  @override
  String get sourceMoveOrdinary => '移入普通区域';

  @override
  String get sourceMoveWarning =>
      '将先撤销该服务的展示、播放和缓存，再迁移成员关系。失败后需重新打开来源；不会自动恢复播放。';

  @override
  String get sourceOperationFailed => '操作失败或访问已撤销；未自动切换来源，请重新检查';

  @override
  String get sourceRenameLine => '线路昵称';

  @override
  String get switchManual => '手动切换';

  @override
  String get playbackLine => '线路';

  @override
  String get playbackLineInUse => '正在使用';

  @override
  String playbackLineFailed(String reason) {
    return '线路切换失败，已继续使用原来的线路：$reason';
  }

  @override
  String get switchLine => '连接线路（同一服务）';

  @override
  String get switchVersion => '来源版本（当前条目）';

  @override
  String get switchCrossSource => '跨服务来源（已确认作品）';

  @override
  String get switchActual => '实际播放来源';

  @override
  String get switchTimeline => '目标时间轴可能不同；请选择续播或从头播放';

  @override
  String get switchMissingLanguage => '目标缺少原语言；请选择目标音轨/字幕，或明确接受默认音轨/关闭字幕';

  @override
  String get switchBeginning => '从头播放';

  @override
  String get switchCurrentPosition => '尝试当前位置';

  @override
  String get switchDefaultAudio => '接受默认音轨';

  @override
  String get switchSubtitlesOff => '关闭字幕';

  @override
  String get switchPending => '正在切换；尚未确认实际播放';

  @override
  String get switchRestore => '恢复原来源（需仍有访问许可）';

  @override
  String get desktopSourceSwitchFailed => '来源切换失败：目标播放窗口未能启动或就绪。未自动恢复或切换来源。';

  @override
  String get desktopSourceRestoreUnavailable => '原来源访问许可已失效，无法恢复。';

  @override
  String get desktopSourceRestoreFailed => '原来源恢复失败，请检查来源后重试。';

  @override
  String get aggregation => '聚合';

  @override
  String get aggregationLibraryScope => '媒体库范围';

  @override
  String get aggregationPrivate => '私密区域';

  @override
  String get aggregationPrivateLocked => '私密区域已锁定，请先在服务管理中解锁';

  @override
  String get aggregationUnavailableDetail => '此来源详情当前不可访问，请返回允许的来源范围';

  @override
  String get aggregationAllowedSources => '全部允许来源';

  @override
  String get aggregationAllSources => '全部普通来源';

  @override
  String get aggregationAllTypes => '全部类型';

  @override
  String get aggregationAllWatching => '全部观看状态';

  @override
  String get aggregationContinue => '继续观看';

  @override
  String get aggregationRecent => '最近更新';

  @override
  String get aggregationLoaded => '已加载作品';

  @override
  String get aggregationLoadedRemote => '远端已加载作品';

  @override
  String get aggregationRemoteEmpty => '远端暂无继续观看项，本机记录仍可用';

  @override
  String get aggregationRemoteConflict => '远端观看时间不可信，请明确选择实际来源（不取最大进度）';

  @override
  String get aggregationComplete => '范围完整';

  @override
  String get aggregationIncomplete => '范围尚不完整 · 仅对已加载结果排序';

  @override
  String get aggregationEmptyScope => '未选择可参与的服务或媒体库';

  @override
  String get aggregationEmpty => '所选范围没有匹配作品';

  @override
  String get aggregationAllFailed => '所选来源全部失败，请逐来源重试';

  @override
  String get aggregationPartialFailure => '部分来源失败，已保留成功结果';

  @override
  String get aggregationRetry => '重试此来源';

  @override
  String get aggregationMore => '加载此来源更多';

  @override
  String get aggregationLocalRecord => '本机确认观看记录';

  @override
  String get aggregationResumeActual => '从本机记录的实际来源继续';

  @override
  String get aggregationSources => '查找同源';

  @override
  String get aggregationConfirmed => '已确认来源';

  @override
  String get aggregationCandidate => '待辨认候选（非确认续播来源）';

  @override
  String get aggregationUnknown => '未知';

  @override
  String get aggregationLoading => '加载中';

  @override
  String get aggregationAvailable => '已返回';

  @override
  String get aggregationTimeout => '超时';

  @override
  String get aggregationOffline => '离线';

  @override
  String get aggregationNeedsLogin => '需登录';

  @override
  String get aggregationForbidden => '无权限';

  @override
  String get aggregationFailed => '查询失败';

  @override
  String get aggregationRevoked => '许可已撤销';

  @override
  String get aggregationEpisodeLookup => '查找此集';

  @override
  String get aggregationEpisodeMapping => '核对分季与分集对应';

  @override
  String get aggregationEpisodeMappingWarning =>
      '仅季号和集号相同不能证明同一集。请先核对两份版本是否采用相同的分季和分集方式；不确定时不会提供可直接续播的来源。';

  @override
  String get aggregationEpisodeMappingConfirm => '已核对，按季与集对应';

  @override
  String get aggregationEpisodeConfirmed => '已确认具体集（不自动跨服续播）';

  @override
  String get aggregationMissingEpisode => '缺少目标集（非查询失败）';

  @override
  String get aggregationEpisodeFailed => '具体集查询失败，可重试';

  @override
  String get aggregationEpisodeUncertain => '分集对应待确认，不可直接跨服续播';

  @override
  String get deviceDetectionFailed => '无法识别设备类型，请重试或以手机模式继续。';

  @override
  String get appInitializationFailed => '无法初始化应用，请重试。';

  @override
  String get continueAsPhone => '以手机模式继续';

  @override
  String get appName => '灯川 Rillight';

  @override
  String get retry => '重试';

  @override
  String get refresh => '刷新';

  @override
  String get posterPlaceholder => '封面不可用';

  @override
  String get unsupported => '不支持';

  @override
  String get connectTitle => '连接服务器';

  @override
  String get serverAddress => '服务器地址';

  @override
  String get serverAddressHint => 'http://192.168.1.8:8096';

  @override
  String get username => '用户名';

  @override
  String get password => '密码';

  @override
  String get showPassword => '显示密码';

  @override
  String get hidePassword => '隐藏密码';

  @override
  String get userAgent => 'User-Agent';

  @override
  String get userAgentHint => '可选，留空则使用默认';

  @override
  String get connect => '连接';

  @override
  String get connecting => '正在连接…';

  @override
  String get logout => '退出登录';

  @override
  String get savedServers => '已保存的服务器';

  @override
  String get lines => '线路';

  @override
  String get noSavedServers => '暂无已保存的服务器';

  @override
  String get addServer => '添加服务器';

  @override
  String get addLine => '添加线路';

  @override
  String get deleteLine => '删除线路';

  @override
  String get editLine => '修改线路地址';

  @override
  String get lineAddressSave => '保存';

  @override
  String get deleteServer => '删除服务器';

  @override
  String deleteServerConfirmMessage(String name) {
    return '删除「$name」会同时清除本机保存的登录凭据，服务器端账号不受影响，之后可重新登录。';
  }

  @override
  String get deleteServerConfirm => '删除';

  @override
  String get changePassword => '修改密码';

  @override
  String get changePasswordCurrent => '旧密码';

  @override
  String get changePasswordCurrentHint => '可留空，由服务器决定是否校验';

  @override
  String get changePasswordNew => '新密码';

  @override
  String get changePasswordConfirm => '确认新密码';

  @override
  String get changePasswordMismatch => '两次输入的新密码不一致';

  @override
  String get changePasswordSubmit => '提交';

  @override
  String get cancelAction => '取消';

  @override
  String get extraLineAddress => '线路地址';

  @override
  String get searchServers => '搜索服务器';

  @override
  String lineCount(int count) {
    return '$count 条线路';
  }

  @override
  String lineSwitchFailed(String detail) {
    return '切换线路失败：$detail';
  }

  @override
  String get librarySize => '库规模';

  @override
  String get libraryCountLoading => '正在获取库规模…';

  @override
  String get libraryCountMovie => '电影';

  @override
  String get libraryCountSeries => '剧集';

  @override
  String get libraryCountEpisode => '单集';

  @override
  String get libraryTypeSeason => '季';

  @override
  String get libraryTypeTrailer => '预告片';

  @override
  String get libraryTypeMusicAlbum => '音乐专辑';

  @override
  String get libraryTypeMusicArtist => '音乐艺人';

  @override
  String get libraryTypeSong => '歌曲';

  @override
  String get libraryTypeMusicVideo => '音乐视频';

  @override
  String get libraryTypeBook => '图书';

  @override
  String get libraryTypePhoto => '照片';

  @override
  String get libraryTypeBoxSet => '合集';

  @override
  String get libraryTypeGame => '游戏';

  @override
  String get libraryTypeAudioPodcast => '播客';

  @override
  String get volume => '音量';

  @override
  String get mute => '静音';

  @override
  String get unmute => '取消静音';

  @override
  String get switchServer => '切换服务器';

  @override
  String connectedTo(String serverName) {
    return '已连接 $serverName';
  }

  @override
  String get errorInvalidAddress => '请输入有效的服务器地址';

  @override
  String get errorUnreachable => '无法连接服务器';

  @override
  String get errorTimeout => '连接超时';

  @override
  String get errorCertificate => '证书错误，无法建立安全连接';

  @override
  String get errorNotEmby => '该地址不是 Emby 服务器';

  @override
  String get errorInvalidCredentials => '用户名或密码错误';

  @override
  String get errorForbidden => '服务器或访问防护拒绝了请求，请检查地址或线路后重试';

  @override
  String get errorSessionExpired => '会话已失效，请重新登录';

  @override
  String get errorUnknown => '连接失败';

  @override
  String get home => '首页';

  @override
  String get libraries => '媒体库';

  @override
  String get customizeNav => '自定义导航';

  @override
  String customizeNavHint(int count) {
    return '最多勾选 $count 个。顶栏放不下的会进「更多」。未勾选的不出现在导航、更多和首页媒体库。';
  }

  @override
  String get saveNav => '保存';

  @override
  String get moveNavUp => '上移';

  @override
  String get moveNavDown => '下移';

  @override
  String volumePercent(int percent) {
    return '$percent%';
  }

  @override
  String get search => '搜索';

  @override
  String get searchHint => '搜索电影或剧集';

  @override
  String get searchEmptyQuery => '输入片名后搜索';

  @override
  String get searchServerFilter => '服务器';

  @override
  String get searchNoResults => '没有结果';

  @override
  String get removeFromResume => '从继续观看移除';

  @override
  String get resumeRow => '继续观看';

  @override
  String get nextUpRow => '即将播放';

  @override
  String get latestMoviesRow => '最近更新的电影';

  @override
  String get latestSeriesRow => '最近更新的剧集';

  @override
  String get more => '更多';

  @override
  String get externalLinks => '外部链接';

  @override
  String get similarRow => '更多类似';

  @override
  String get episodesRow => '集';

  @override
  String get seasonEpisodes => '本季分集';

  @override
  String get episodesLoadMore => '加载更多';

  @override
  String get sortBy => '排序';

  @override
  String get libraryFilter => '筛选';

  @override
  String get libraryFilterClear => '清除筛选';

  @override
  String get libraryFilterCancel => '取消';

  @override
  String get minimizeWindow => '最小化';

  @override
  String get libraryFilterType => '类型';

  @override
  String get libraryFilterWatch => '观看状态';

  @override
  String get libraryFilterYear => '年份';

  @override
  String get libraryFilterGenre => '流派';

  @override
  String get libraryFilterAll => '全部';

  @override
  String get sortByName => '标题';

  @override
  String get sortByDateUpdated => '更新日期';

  @override
  String get sortByDateCreated => '加入日期';

  @override
  String get sortByPremiereDate => '首映日期';

  @override
  String get sortByCommunityRating => 'IMDb评分';

  @override
  String get sortByCriticRating => '影评人评分';

  @override
  String get sortByProductionYear => '出品年份';

  @override
  String get sortByOfficialRating => '官方评级';

  @override
  String get sortByDatePlayed => '播放日期';

  @override
  String get sortByRuntime => '播放时长';

  @override
  String get sortByRandom => '随机';

  @override
  String get sortByRating => 'IMDb评分';

  @override
  String get sortByIndexNumber => '集数';

  @override
  String get scrollLeft => '向左';

  @override
  String get scrollRight => '向右';

  @override
  String get switchLibrary => '切换媒体库';

  @override
  String get collapseNav => '收起导航';

  @override
  String get expandNav => '展开导航';

  @override
  String get markPlayed => '标记已看';

  @override
  String get markUnplayed => '标记未看';

  @override
  String get overview => '简介';

  @override
  String get seasons => '季';

  @override
  String seasonCount(int count) {
    return '共$count季';
  }

  @override
  String get errorLoadFailed => '加载失败';

  @override
  String get errorSearchFailed => '搜索失败';

  @override
  String get itemUnavailable => '条目不可用';

  @override
  String episodeCount(int count) {
    return '$count 集';
  }

  @override
  String runtimeHoursMinutes(int hours, int minutes) {
    return '$hours小时$minutes分钟';
  }

  @override
  String runtimeMinutes(int minutes) {
    return '$minutes分钟';
  }

  @override
  String playbackProgress(int percent) {
    return '已看 $percent%';
  }

  @override
  String remainingMinutes(int minutes) {
    return '剩余 $minutes 分钟';
  }

  @override
  String get play => '播放';

  @override
  String get details => '详情';

  @override
  String get heroNewMovie => '最新电影';

  @override
  String get heroNewSeries => '最新剧集';

  @override
  String heroItemOf(int index, int count) {
    return '第 $index 项，共 $count 项';
  }

  @override
  String get browseEmpty => '暂无可浏览的内容，请刷新或从媒体库开始浏览。';

  @override
  String browseLoaded(int count) {
    return '已载入 $count 项';
  }

  @override
  String get pauseCarousel => '暂停轮播';

  @override
  String get resumeCarousel => '恢复轮播';

  @override
  String get pause => '暂停';

  @override
  String get resumePlay => '继续播放';

  @override
  String playEpisode(String code) {
    return '播放 $code';
  }

  @override
  String resumePlayEpisode(String code) {
    return '继续播放 $code';
  }

  @override
  String get viewSeries => '查看剧集';

  @override
  String get nextEpisode => '下一集';

  @override
  String get previousEpisode => '上一集';

  @override
  String get locateEpisode => '跳转到此集';

  @override
  String get pickEpisode => '选集';

  @override
  String get jumpToEpisodeHint => '输入集数，回车跳转';

  @override
  String get nowPlayingEpisode => '正在观看';

  @override
  String get playFromStart => '从头播放';

  @override
  String get playbackEnded => '播放结束';

  @override
  String get replay => '重播';

  @override
  String get closePlayer => '关闭';

  @override
  String get resumePrompt => '要从上次的位置继续播放吗？';

  @override
  String get fullscreen => '全屏';

  @override
  String get exitFullscreen => '退出全屏';

  @override
  String get directPlay => '直连';

  @override
  String get transcode => '转码';

  @override
  String get quality => '画质';

  @override
  String get qualityAuto => '最高可用';

  @override
  String qualityMbps(int mbps) {
    return '$mbps Mbps';
  }

  @override
  String get networkSlowHint => '网络较慢，已保持当前画质；可手动切换画质';

  @override
  String get chapters => '章节';

  @override
  String get phoneAlbum => '相册';

  @override
  String get mediaSource => '片源';

  @override
  String get audioTrack => '音轨';

  @override
  String get subtitleTrack => '字幕';

  @override
  String get subtitleOff => '关闭字幕';

  @override
  String get subtitleMetaExternal => '外挂';

  @override
  String get subtitleMetaEmbedded => '内嵌';

  @override
  String get trackMetaDefault => '默认';

  @override
  String trackPickerCount(int count) {
    return '共 $count 条';
  }

  @override
  String get subtitleBitmapBurnIn => '该字幕为位图，将请求服务器烧录';

  @override
  String get subtitleBitmapFailed => '直连无法渲染该字幕，请改用转码';

  @override
  String nextEpisodeIn(int seconds) {
    return '$seconds 秒后播放下一集';
  }

  @override
  String get cancelNextEpisode => '取消';

  @override
  String get playNextEpisode => '播放下一集';

  @override
  String get playbackDisconnected => '播放中断，请检查网络';

  @override
  String get progressSyncFailed => '进度同步失败';

  @override
  String get progressSyncFailedMain => '播放进度未能同步';

  @override
  String get playbackSessionExpired => '会话已过期，进度无法保存';

  @override
  String get playbackFailed => '无法播放';

  @override
  String get noPlayableStream => '没有可播放的流';

  @override
  String get playerPlaying => '正在播放';

  @override
  String get playerBuffering => '正在缓冲…';

  @override
  String get playerLoading => '正在打开播放…';

  @override
  String get playerNetworkSpeedTooltip => '实时网速';

  @override
  String get settings => '设置';

  @override
  String get settingsPlayback => '播放';

  @override
  String get settingsAppearance => '外观';

  @override
  String get settingsAppearanceHint => '浅色、深色或跟随系统';

  @override
  String get appearanceSystem => '跟随系统';

  @override
  String get appearanceLight => '浅色';

  @override
  String get appearanceDark => '深色';

  @override
  String get settingsDiskCacheLimit => '磁盘缓冲上限';

  @override
  String get settingsDiskCacheLimitHint => '限制本地缓冲占用；达到上限后，随播放进度自动释放旧片段并缓存后续内容';

  @override
  String get settingsHardwareDecoding => '硬件解码';

  @override
  String get settingsHardwareDecodingHint =>
      '优先使用可用的硬件解码，失败时回退软件解码；实际启用状态以播放诊断为准';

  @override
  String get settingsHardwareDecodingAuto => '自动';

  @override
  String get settingsHardwareDecodingOn => '开启';

  @override
  String get settingsHardwareDecodingOff => '关闭';

  @override
  String get settingsDecoderBackend => '解码后端';

  @override
  String get settingsDecoderBackendHint => '不确定时保持自动即可';

  @override
  String get settingsBackendAuto => '自动';

  @override
  String get settingsBackendD3d11va => 'D3D11VA';

  @override
  String get settingsBackendNvdec => 'NVDEC';

  @override
  String get settingsBackendVideotoolbox => 'VideoToolbox';

  @override
  String get settingsRestoreDefaults => '恢复默认';

  @override
  String get settingsAppliesToNewPlayback => '更改对新起播生效';

  @override
  String settingsCacheSize(double gb) {
    return '$gb GB';
  }

  @override
  String get settingsDanmakuService => '弹幕服务';

  @override
  String get settingsDanmakuServiceHint => '官方源需 AppId；国产剧可改用兼容自建服务';

  @override
  String get settingsShowToken => '显示令牌';

  @override
  String get settingsHideToken => '隐藏令牌';

  @override
  String get settingsDanmakuServer => '自定义服务地址';

  @override
  String get settingsDanmakuServerHint => '留空使用官方源';

  @override
  String get settingsDanmakuAppId => '官方 AppId';

  @override
  String get settingsDanmakuAppIdHint => '官方源必填，在弹弹play 开放平台申请';

  @override
  String get settingsDanmakuToken => '访问令牌';

  @override
  String get settingsDanmakuTokenHint => '官方源填 AppSecret；自定义服务填访问令牌';

  @override
  String get playbackRate => '倍速';

  @override
  String get playerPlaybackSettings => '播放设置';

  @override
  String get alwaysOnTop => '窗口置顶';

  @override
  String get alwaysOnTopOff => '取消置顶';

  @override
  String get playerEpisodes => '剧集';

  @override
  String get skipIntro => '跳过片头';

  @override
  String get skipOutro => '跳过片尾';

  @override
  String get danmaku => '弹幕';

  @override
  String get danmakuSettings => '弹幕设置';

  @override
  String get danmakuOpacity => '不透明度';

  @override
  String get danmakuFontSize => '字号';

  @override
  String get danmakuSpeed => '弹幕速度';

  @override
  String get danmakuDisplayArea => '显示区域';

  @override
  String get danmakuDensity => '同屏数量';

  @override
  String get danmakuUnlimited => '不限';

  @override
  String get danmakuSearch => '搜索';

  @override
  String get danmakuSearchTitle => '搜索弹幕';

  @override
  String get danmakuSearchHint => '输入动画或影视名称';

  @override
  String get danmakuMatchHint => '未匹配到弹幕，点此搜索';

  @override
  String get danmakuNoMatch => '未匹配到弹幕';

  @override
  String get danmakuMatching => '弹幕匹配中…';

  @override
  String danmakuMatchedTo(String title) {
    return '已匹配：$title';
  }

  @override
  String get danmakuCustomUnreachable => '自定义弹幕服务不可用';

  @override
  String get danmakuUseOfficial => '使用官方源';

  @override
  String get danmakuOfficial => '官方源';

  @override
  String get danmakuCustom => '自定义源';

  @override
  String get danmakuOfficialUnreachable => '弹幕服务不可达';

  @override
  String get danmakuOfficialNeedsAuth => '未配置 AppId';

  @override
  String get danmakuOfficialSetupHint =>
      '在主窗口「设置 → 弹幕服务」填写官方 AppId 与 AppSecret，或改用自定义服务。';

  @override
  String get danmakuNoComments => '本集无弹幕';

  @override
  String danmakuLoadedCount(int count) {
    return '已加载 $count 条';
  }

  @override
  String get danmakuFontScaleSmall => '小';

  @override
  String get danmakuFontScaleMedium => '中';

  @override
  String get danmakuFontScaleLarge => '大';

  @override
  String get danmakuFontScaleExtraLarge => '特大';

  @override
  String get danmakuSpeedSlow => '慢';

  @override
  String get danmakuSpeedNormal => '标准';

  @override
  String get danmakuSpeedFast => '快';

  @override
  String get danmakuSpeedVeryFast => '极快';

  @override
  String get danmakuAreaQuarter => '1/4屏';

  @override
  String get danmakuAreaHalf => '半屏';

  @override
  String get danmakuAreaThreeQuarters => '3/4屏';

  @override
  String get danmakuAreaFull => '全屏';

  @override
  String get danmakuTypeScroll => '滚动';

  @override
  String get danmakuTypeTop => '顶部';

  @override
  String get danmakuTypeBottom => '底部';

  @override
  String get danmakuColorful => '彩色';

  @override
  String get danmakuAdvanced => '高级';

  @override
  String get danmakuPreventOverlap => '防重叠';

  @override
  String get danmakuMergeDuplicates => '合并重复';

  @override
  String get danmakuOutline => '描边';

  @override
  String get danmakuFollowPlaybackRate => '跟随倍速';

  @override
  String get danmakuDensityAuto => '自动';

  @override
  String get danmakuDensitySparse => '稀疏';

  @override
  String get danmakuDensityDense => '密集';

  @override
  String get danmakuTimeOffset => '时间偏移';

  @override
  String get danmakuTimeOffsetStepDown => '−0.5 秒';

  @override
  String get danmakuTimeOffsetStepUp => '+0.5 秒';

  @override
  String get danmakuTimeOffsetZero => '归零';

  @override
  String get danmakuBlockedKeywords => '屏蔽关键词';

  @override
  String get danmakuKeywordHint => '输入关键词后回车';

  @override
  String get danmakuRestoreDefaults => '恢复默认';

  @override
  String get danmakuEpisodes => '分集';

  @override
  String get detailOverview => '概览';

  @override
  String get detailCast => '演职员';

  @override
  String get detailMediaInfo => '媒体信息';

  @override
  String get detailMetadata => '元数据';

  @override
  String get expand => '展开';

  @override
  String get collapse => '收起';

  @override
  String premiereDate(String date) {
    return '首播 $date';
  }

  @override
  String get dateAdded => '入库日期';

  @override
  String dateAddedOn(String date) {
    return '入库 $date';
  }

  @override
  String get personTypeActor => '演员';

  @override
  String get personTypeDirector => '导演';

  @override
  String get personTypeWriter => '编剧';

  @override
  String get personTypeOther => '其他';

  @override
  String get videoTrack => '视频';

  @override
  String audioChannels(int channels) {
    return '$channels 声道';
  }

  @override
  String get mobileMine => '我的';

  @override
  String get mobileEmpty => '暂无内容';

  @override
  String get mobileLoadMore => '加载更多';

  @override
  String get mobileAllLoaded => '已显示全部内容';

  @override
  String get mobileConnectionHint => '连接你的 Emby 服务器。重启后会恢复已保存的会话；未提交的密码需要重新输入。';

  @override
  String get mobileBackgroundPaused => '已暂停，点击播放继续';

  @override
  String get mobilePreviousSession => '上次播放已中断，可从详情页继续观看。';

  @override
  String get mobileRecoveryFailed => '上次播放进度同步失败，请重试。';

  @override
  String get mobileRefresh => '刷新';

  @override
  String get mobileBack => '返回';

  @override
  String get mobileTracks => '音轨与字幕';

  @override
  String get mobilePause => '暂停';

  @override
  String get mobileForward => '快进 10 秒';

  @override
  String get mobileRewind => '后退 10 秒';

  @override
  String get mobileSpeed => '播放速度';

  @override
  String get mobileLine => '服务器线路';

  @override
  String get tvSettingsOther => '其他';

  @override
  String get tvSettingsCurrent => '当前';

  @override
  String get tvViewAll => '查看全部';

  @override
  String get tvConnectHint => '输入 Emby 服务器地址与账号即可开始观看。也可以用手机扫码,在手机上填写。';

  @override
  String get tvConnectOr => '或';

  @override
  String get tvUserAgentOptional => 'User-Agent(可选)';

  @override
  String get mobileAddServer => '连接其他服务器';

  @override
  String get mobileAccountServerGroup => '账户与服务器';

  @override
  String get phoneAppearanceGroup => '外观';

  @override
  String get phoneFloatingNav => '悬浮导航栏';

  @override
  String get phoneFloatingNavHint => '离开底边，页面从背后滑过';

  @override
  String get mobilePlaybackGroup => '播放设置';

  @override
  String get mobileCacheGroup => '缓存';

  @override
  String get mobileAboutGroup => '关于';

  @override
  String mobileVersion(String version) {
    return '版本 $version';
  }

  @override
  String get mobileSort => '排序';

  @override
  String get mobileNameSort => '名称';

  @override
  String get mobileDateSort => '最近添加';

  @override
  String get mobileWatched => '已看';

  @override
  String get mobileUnwatched => '未看';

  @override
  String get mobileMovies => '电影';

  @override
  String get mobileSeries => '剧集';

  @override
  String get mobileLock => '锁定屏幕';

  @override
  String get mobileUnlock => '解锁屏幕';

  @override
  String get mobileGestureUnavailable => '系统调节暂不可用';

  @override
  String get mobileSource => '来源';

  @override
  String get mobileSourceSwitching => '正在切换来源…';

  @override
  String get mobileSourceConfirming => '正在确认当前来源…';

  @override
  String get mobileSourceSwitchFailed => '来源切换失败，原来源已恢复';

  @override
  String get mobileSourceSwitchFailedRetry => '来源切换失败，请重试';

  @override
  String get mobileLockedHint => '已锁定 · 点右上角解锁';

  @override
  String get mobileMore => '更多';

  @override
  String get mobileTrackUnavailable => '此轨道在当前设备上不可用';

  @override
  String get mobileDanmakuPanel => '弹幕设置';

  @override
  String get mobileAppVolume => '应用内音量';

  @override
  String get phoneHomeSections => '首页区块';

  @override
  String get phoneHomeEdit => '编辑首页';

  @override
  String get phoneHomeEditHint => '按住左侧手柄拖动排序。关闭的行会归到「未显示」。媒体库页仍会列出全部媒体库。';

  @override
  String get phoneHomeSectionBanner => '轮播图';

  @override
  String get phoneHomeSectionNextUp => '下一集';

  @override
  String get phoneHomeSectionLatestMovies => '最近电影';

  @override
  String get phoneHomeSectionLatestSeries => '最近剧集';

  @override
  String get phoneHomeSectionLibraries => '媒体库';

  @override
  String phoneHomeLibraryLatest(String name) {
    return '$name';
  }

  @override
  String get phoneHomeShown => '显示中';

  @override
  String get phoneHomeHidden => '未显示';

  @override
  String get phoneHomeSectionMoveUp => '上移';

  @override
  String get phoneHomeSectionMoveDown => '下移';

  @override
  String phoneHomeSectionVisible(String name) {
    return '显示$name';
  }

  @override
  String get playerFit => '适应';

  @override
  String get playerFill => '填充';

  @override
  String get settingsCategoriesHint => '展开分类调整设置，再次点击可收起。修改会自动保存。';

  @override
  String get settingsBackToCategories => '返回设置分类';

  @override
  String get settingsPlaybackSummary => '倍速、片头片尾、缓冲与硬件解码';

  @override
  String get settingsDanmakuDisplaySummary => '字号、不透明度、显示区域与屏蔽词';

  @override
  String get settingsSkipIntro => '片头提示';

  @override
  String get settingsSkipIntroHint => '手动跳过片头';

  @override
  String get settingsSkipOutro => '片尾提示';

  @override
  String get settingsSkipOutroHint => '片尾可跳过或进入下一集';

  @override
  String get playerSkipSettings => '片头与片尾';

  @override
  String get playerSettingOn => '开启';

  @override
  String get playerSettingOff => '关闭';

  @override
  String playerSkipSettingsSummary(String intro, String outro) {
    return '片头$intro · 片尾$outro';
  }

  @override
  String get playerSkipSettingsSaved => '自动保存，应用于所有视频';

  @override
  String get nextEpisodeHeading => '接下来播放';

  @override
  String get nextEpisodeKeepWatching => '继续看本集';

  @override
  String get nextEpisodeStay => '暂不播放';

  @override
  String get settingsSaveFailed => '设置保存失败，请重试';

  @override
  String get playerPictureSettings => '画面与音量';

  @override
  String get albumDownload => '下载原图';

  @override
  String get albumDownloadSaved => '图片已保存';

  @override
  String get albumDownloadFailed => '图片保存失败，请重试';

  @override
  String get albumPrevious => '上一张';

  @override
  String get albumNext => '下一张';

  @override
  String get playbackDolbyVisionUnsupported =>
      '此杜比视界版本需要专用色彩处理，当前无法播放，服务器也未提供兼容转码。请切换 HDR10 或 SDR 版本。';

  @override
  String get settingsDanmakuConfiguration => '弹幕配置';

  @override
  String get settingsDanmakuConfigurationSummary => '显示样式、屏蔽词与服务连接';

  @override
  String get danmakuPreview => '样式预览';

  @override
  String get danmakuPreviewText => '一起看剧，弹幕也清晰舒适';

  @override
  String get phoneServerManagement => '服务器管理';

  @override
  String get phoneServerManagementHint => '切换服务器，管理连接地址和保存的账号';

  @override
  String get phoneCurrentServer => '正在使用';

  @override
  String get phoneManageServer => '管理服务器';

  @override
  String get phoneRenameServer => '修改显示名称';

  @override
  String get phoneServerName => '显示名称';

  @override
  String get phoneServerNameHint => '留空使用服务器名称';

  @override
  String get phoneEmptyServers => '还没有保存的服务器';

  @override
  String get phoneNoMatchingServers => '没有找到匹配的服务器';

  @override
  String get phoneOperationFailed => '操作失败，请重试';

  @override
  String get phoneDeleteCurrentServerHint => '删除正在使用的服务器后，会退出当前登录';

  @override
  String get phoneManageSavedServers => '管理已保存的服务器';

  @override
  String get undoAction => '撤销';

  @override
  String get phoneGestureSeek => '滑动定位，松开后跳转';

  @override
  String phoneServerDeleted(String name) {
    return '已删除「$name」';
  }

  @override
  String cardSeasonCount(int count) {
    return '$count季';
  }

  @override
  String get filterApply => '应用筛选';

  @override
  String get filterReset => '重置';

  @override
  String filterSelectedCount(int count) {
    return '已选 $count 项';
  }

  @override
  String get filterSearchOptions => '查找选项';

  @override
  String get filterNoOptions => '暂无可选项';

  @override
  String get filterFavorite => '收藏';

  @override
  String get filterResumable => '继续观看';

  @override
  String get filterChooseHint => '同一分类可选多项，不同分类组合筛选';

  @override
  String get filterBrowseTitle => '筛选与排序';

  @override
  String get filterEdit => '调整';

  @override
  String get filterSortAscending => '升序';

  @override
  String get filterSortDescending => '降序';

  @override
  String get phoneDiscover => '发现好故事';

  @override
  String get phoneLibraryBrowse => '浏览媒体库';

  @override
  String get phoneSearchHint => '搜索电影、剧集和演员';

  @override
  String phoneSelectedSeason(int count) {
    return '本季 $count 集';
  }

  @override
  String get phoneSubtitleSize => '字幕大小';

  @override
  String get phoneSubtitleSmall => '小';

  @override
  String get phoneSubtitleStandard => '标准';

  @override
  String get phoneSubtitleLarge => '大';

  @override
  String get phoneSubtitleExtraLarge => '特大';

  @override
  String get phoneSubtitleOriginal => '使用原始 ASS 样式';

  @override
  String get phoneSubtitleOriginalHint => '保留字幕作者的字号与特效排版';

  @override
  String get phoneSubtitleUnavailable => '当前没有独立可调的文字字幕；图片字幕和画面内文字不支持字号调整';

  @override
  String get phonePictureInPicture => '画中画';

  @override
  String get phonePipUnavailable => '当前设备或系统设置不支持画中画';

  @override
  String get phonePipFailed => '无法进入画中画，请检查系统权限';

  @override
  String get tvSectionMoveUp => '上移';

  @override
  String get tvSectionMoveDown => '下移';

  @override
  String get tvLanAssist => '手机辅助连接';

  @override
  String get tvLanScanTitle => '用手机扫码登录';

  @override
  String get tvLanScanHint => '用手机相机扫码,在手机上填写服务器与账号,提交后回到电视确认即可完成登录';

  @override
  String get tvLanPendingTitle => '手机已提交,确认后登录';

  @override
  String get tvLanWaiting => '等待手机提交';

  @override
  String get tvLanConfirm => '确认连接';

  @override
  String get tvLanReject => '拒绝';

  @override
  String get tvLanExpired => '辅助连接已过期';

  @override
  String get tvLanFailed => '辅助连接未完成';

  @override
  String get tvLanFingerprint => '证书指纹';

  @override
  String get tvLanAddress => '局域网地址';

  @override
  String tvLanValidUntil(String time) {
    return '本次配对有效至 $time';
  }
}
