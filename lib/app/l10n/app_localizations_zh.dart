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
  String get aggregationPrivateLocked => '私密区域已锁定，请先在服务管理中解锁';

  @override
  String get aggregationUnavailableDetail => '暂时无法打开此服务器的内容，请返回重试。';

  @override
  String get aggregationEmpty => '暂无内容';

  @override
  String get aggregationAllFailed => '所选来源全部失败，请逐来源重试';

  @override
  String get aggregationPartialFailure => '部分来源失败，已保留成功结果';

  @override
  String get aggregationRetry => '重试此来源';

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
  String get episodesRow => '剧集';

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
    return '共 $count 项';
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
  String get playbackOutputSection => '实际输出';

  @override
  String get playbackOutputSource => '片源';

  @override
  String get playbackOutputVideo => '实际视频输出';

  @override
  String get playbackOutputAudio => '实际音频输出';

  @override
  String get playbackOutputDecode => '解码路径';

  @override
  String get playbackOutputUnknown => '未知';

  @override
  String get playbackOutputNone => '无';

  @override
  String get playbackOutputNotDolby => '非杜比视界';

  @override
  String playbackOutputProfile(int profile) {
    return '杜比视界 Profile $profile';
  }

  @override
  String playbackOutputBaseLayer(String layer) {
    return '基础层 $layer';
  }

  @override
  String get playbackOutputBaseHdr10 => 'HDR10';

  @override
  String get playbackOutputBaseSdr => 'SDR';

  @override
  String get playbackOutputBaseHlg => 'HLG';

  @override
  String get playbackOutputSdr => 'SDR 映射';

  @override
  String get playbackOutputHdr => 'HDR';

  @override
  String get playbackOutputHdrScRgb => 'HDR（scRGB）';

  @override
  String get playbackOutputHdrEdr => 'HDR（EDR）';

  @override
  String get playbackOutputHdrPq => 'HDR（PQ）';

  @override
  String get playbackOutputNativeDolby => '原生杜比视界';

  @override
  String get playbackOutputReconRpu => 'RPU';

  @override
  String get playbackOutputReconFel => 'FEL';

  @override
  String get playbackOutputReconBase => '基础层回退';

  @override
  String get playbackOutputDisplayHdrOn => '显示器 HDR：开启';

  @override
  String get playbackOutputDisplayHdrOff => '显示器 HDR：关闭';

  @override
  String get playbackOutputAudioStereo => '立体声 PCM';

  @override
  String get playbackOutputAudioDownmix => '立体声下混';

  @override
  String playbackOutputAudioChannels(int channels) {
    return '$channels 声道 PCM';
  }

  @override
  String get playbackOutputAudioPassthrough => '压缩透传';

  @override
  String get playbackOutputAudioAtmos => 'Atmos 透传';

  @override
  String get playbackOutputRequested => '请求';

  @override
  String get playbackOutputEffective => '生效';

  @override
  String get playbackOutputIdle => '未在播放，实际输出未知';

  @override
  String get settingsOutputSummary => '播放时显示实际的视频解码与音频输出';

  @override
  String get playbackOutputSpeedPcm => '倍速播放时压缩透传不可用，当前输出为 PCM。';

  @override
  String get playbackOutputBaseFallback => '残差合成失败，当前是基础层回退，不是 FEL 完成。';

  @override
  String get playbackOutputProfile5MissingRpu =>
      'Profile 5 没有可用 RPU，不能按普通 HDR10 或 YUV 输出。';

  @override
  String playbackOutputFrameRate(String rate) {
    return '目标显示帧率 $rate fps';
  }

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
  String get homeFailureEmptyTitle => '这个服务器还没有内容';

  @override
  String get homeFailureEmptyWithLibrariesMessage =>
      '媒体库里还没有可显示的影片或剧集。可以先去媒体库整理内容，或刷新后重试。';

  @override
  String get homeFailureEmptyNoLibrariesMessage =>
      '服务器还没有提供任何媒体库。可以切换服务器，或刷新后重试。';

  @override
  String get homeFailureDeviceOfflineTitle => '设备未联网';

  @override
  String get homeFailureDeviceOfflineMessage =>
      '当前设备没有可用的网络连接，请检查 Wi-Fi 或网线后重试。';

  @override
  String get homeFailureServerOfflineTitle => '无法连接服务器';

  @override
  String get homeFailureServerOfflineMessage => '服务器没有响应，请确认服务器已启动，或切换到其他线路。';

  @override
  String get homeFailureLoadFailedTitle => '内容加载失败';

  @override
  String get homeFailureGoToLibraries => '去媒体库';

  @override
  String get homeFailureSwitchRoute => '更换线路';

  @override
  String get mobileEmpty => '暂无内容';

  @override
  String get mobileLoadMore => '加载更多';

  @override
  String get mobileAllLoaded => '已显示全部内容';

  @override
  String get mobileConnectionHint => '登录你的媒体服务器，开始观看。';

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
  String get tvConnectHint => '连接你的媒体服务器，开始观看。Emby 账号也可以用手机扫码填写。';

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
  String get phoneHomeEditHint => '按住左侧手柄拖动排序。关闭的行会归到「未显示」。仍可从首页进入媒体库。';

  @override
  String get configurationUpgradeFailed => '配置升级未完成，原始配置已保留。';

  @override
  String get historyRecoveryFailed => '播放记录暂时无法读取';

  @override
  String get historyRecoveryHint => '请保留下面的原始文件；修复文件或从已存在的备份恢复后重试。';

  @override
  String get configurationRecoveryHint =>
      '请先重试。若仍失败，请保留配置目录中的原始文件、.pre-v4 备份与迁移记录，再恢复配置。';

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
  String get phoneSubtitleOriginal => '原始 ASS 样式';

  @override
  String get phoneSubtitleOriginalHint => '保留作者字号与特效；选择上方字号将关闭此项';

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
  String get tvLanAddress => '局域网地址';

  @override
  String tvLanValidUntil(String time) {
    return '本次配对有效至 $time';
  }

  @override
  String get detailEpisodesHeader => '剧集';

  @override
  String get detailInfo => '详细信息';

  @override
  String get premiereDateLabel => '首播日期';

  @override
  String get runtimeRowLabel => '时长';

  @override
  String get fileContainerLabel => '容器';

  @override
  String get fileSizeLabel => '文件大小';

  @override
  String get fileBitrateLabel => '码率';

  @override
  String seasonWatchedCount(int watched, int total) {
    return '已看 $watched/$total';
  }

  @override
  String get watchedAction => '已看';

  @override
  String get providerConnectTitle => '连接媒体服务';

  @override
  String get providerServiceType => '服务类型';

  @override
  String get providerConnectEntry => '添加 Emby / Jellyfin / Plex';

  @override
  String get providerPlexAuthorize => '使用 Plex 账号授权';

  @override
  String get providerQuickConnect => '使用 Quick Connect';

  @override
  String get providerPlexInstructions => '请在浏览器中登录 Plex 并完成授权。也可用手机打开下方地址。';

  @override
  String get providerQuickInstructions =>
      '在已登录的 Jellyfin 应用中打开 Quick Connect，输入下方代码。';

  @override
  String get providerOpenBrowser => '打开浏览器';

  @override
  String get providerWaitingAuthorization => '等待授权…';

  @override
  String get providerDiscovering => '正在发现服务器…';

  @override
  String get providerRestart => '重新授权';

  @override
  String get providerChooseHome => 'Plex Home 用户';

  @override
  String get providerHomePin => 'Plex Home PIN';

  @override
  String get providerHomePinHint => '请输入 Plex Home 用户的 PIN，不是灯川私密 PIN。';

  @override
  String get providerSwitchHome => '切换用户并重新发现服务器';

  @override
  String get providerChooseResource => '选择服务器与连接线路';

  @override
  String get providerNoResources => '当前用户没有可用服务器，请选择 Home 用户或重新授权。';

  @override
  String get providerLocal => '本地';

  @override
  String get providerRemote => '远程';

  @override
  String get providerRelay => '中继（带宽受限）';

  @override
  String get providerChooseLibraries => '已连接。勾选参与聚合的影视库；不勾选仍可单独浏览此服务。';

  @override
  String get providerNoLibraries => '没有发现可访问的影视库。可重试或保留空范围。';

  @override
  String get providerFinish => '保存并完成';

  @override
  String get providerCredentialsRejected => '账号、密码或 Home PIN 不正确，请重试。';

  @override
  String get providerPermissionDenied => '当前账号无权访问，请检查共享权限或重新授权。';

  @override
  String get providerRateLimited => '服务暂时限制请求，请稍后重试。';

  @override
  String get providerAuthorizationExpired => '授权已过期、被拒绝或取消，请重新授权。';

  @override
  String get providerSignatureFailure => '授权签名或设备时间校验失败，请校准系统时间后重试。';

  @override
  String get providerQuickUnavailable => '服务器未开放 Quick Connect，请使用密码登录。';

  @override
  String get providerCertificateFailure => '服务器证书校验失败，请检查服务器配置。';

  @override
  String get providerConnectionFailure => '连接未完成，请检查地址和网络后重试。';

  @override
  String get providerBrowserFailure => '无法打开浏览器，请在其它设备打开授权地址。';

  @override
  String get providerHomeManage => '切换 Plex Home 用户';

  @override
  String get providerServerOrder => '此列表按服务器提供的顺序显示';

  @override
  String get providerOwned => '自有服务器';

  @override
  String get providerShared => '共享服务器';

  @override
  String get providerAccountManage => 'Plex 账号设置';

  @override
  String get providerAccountInstructions =>
      'Plex 账号与密码在官方网页中管理。请打开浏览器，或在手机上访问下方地址。';

  @override
  String get loginWelcomeTitle => '连接你的媒体库';

  @override
  String get loginWelcomeSubtitle => '登录 Emby、Jellyfin 或 Plex 服务器，在这台设备上继续观看。';

  @override
  String get loginServiceLabel => '服务类型';

  @override
  String get loginEmbyHint => '填写服务器地址与账号密码登录 Emby。';

  @override
  String get loginJellyfinHint => '使用账号密码登录，或在已登录的设备上用 Quick Connect 授权。';

  @override
  String get loginPlexHint => '使用 Plex 账号授权，自动发现你可以访问的服务器。';

  @override
  String get loginAdvanced => '高级选项';

  @override
  String get loginPlexTitle => '使用 Plex 账号登录';

  @override
  String get loginPlexStep1 => '点击下方按钮，在浏览器中打开 plex.tv 授权页';

  @override
  String get loginPlexStep2 => '登录 Plex 账号，允许灯川访问';

  @override
  String get loginPlexStep3 => '回到这里，选择服务器与连接线路';

  @override
  String get loginQuickConnectHint => '无需输入密码';

  @override
  String get loginSavedServersHint => '选择一台服务器，自动填入地址与账号';

  @override
  String loginServerCount(int count) {
    return '$count 台服务器';
  }

  @override
  String get providerCopyCode => '复制代码';

  @override
  String get providerCodeCopied => '代码已复制';

  @override
  String get providerAuthorizationCodeLabel => '授权代码';

  @override
  String get providerSelectAll => '全选';

  @override
  String get providerSelectNone => '全不选';

  @override
  String get playerShowRemaining => '显示剩余时间';

  @override
  String get playerShowDuration => '显示总时长';

  @override
  String playerRemainingClock(String time) {
    return '-$time';
  }

  @override
  String playerEndsAt(String time) {
    return '$time 结束';
  }

  @override
  String get phoneLibrariesMine => '我的媒体库';

  @override
  String get phoneLibrariesShortcuts => '快速入口';

  @override
  String get phoneShortcutLatestMovies => '最新电影';

  @override
  String get phoneShortcutLatestSeries => '最新剧集';

  @override
  String phoneLibraryCount(int count) {
    return '$count 个媒体库';
  }

  @override
  String get phoneSearchRecent => '最近搜索';

  @override
  String get phoneSearchClearRecent => '清除';

  @override
  String get phoneSearchIdleTitle => '想看点什么？';

  @override
  String phoneSearchResultCount(int count) {
    return '$count 个结果';
  }

  @override
  String get phoneFavorite => '收藏';

  @override
  String get phoneFavorited => '已收藏';

  @override
  String get phoneFavoriteAdded => '已加入收藏';

  @override
  String get phoneFavoriteRemoved => '已取消收藏';

  @override
  String get phoneFavoriteFailed => '收藏没有保存，请稍后再试';

  @override
  String get subtitleTrackPrimary => '主字幕';

  @override
  String get subtitleTrackSecondary => '次字幕';

  @override
  String get subtitleImportLocal => '导入本地字幕…';

  @override
  String get subtitleImportRunning => '正在导入字幕…';

  @override
  String get subtitleImportDuplicate => '相同内容的字幕已在候选列表中';

  @override
  String get subtitleImportInvalid => '不是有效的 SRT/ASS/SSA/VTT UTF-8 字幕文件';

  @override
  String get subtitleImportTooLarge => '字幕文件超过单文件大小限制';

  @override
  String get subtitleImportSessionLimit => '会话内字幕文件总大小已达上限';

  @override
  String get subtitleImportUnreadable => '字幕文件无法读取';

  @override
  String get subtitleImportPickerUnavailable => '此设备没有可用的文件选择器';

  @override
  String get subtitleSlotOccupied => '该来源已在另一字幕槽位使用';

  @override
  String get subtitleBurnInSecondary => '烧录字幕无法作为可独立关闭的次字幕';

  @override
  String get subtitleMetaImported => '本地导入';

  @override
  String get backupImportEntry => '导入备份';

  @override
  String get backupImportPickerTitle => '选择备份文件';

  @override
  String get backupImportWorking => '正在读取备份…';

  @override
  String get backupImportResultTitle => '备份导入结果';

  @override
  String get backupImportFailureTitle => '备份导入未完成';

  @override
  String get backupImportClose => '关闭';

  @override
  String backupImportAddedCount(int count) {
    return '新增 $count 台';
  }

  @override
  String backupImportCredentialsReady(int count) {
    return '已带凭据 $count 个';
  }

  @override
  String backupImportPendingLogin(int count) {
    return '待登录 $count 个';
  }

  @override
  String backupImportDuplicateCount(int count) {
    return '重复跳过 $count 台';
  }

  @override
  String backupImportNonTargetCount(int count) {
    return '不支持的服务类型 $count 条';
  }

  @override
  String backupImportFailedCount(int count) {
    return '失败 $count 条';
  }

  @override
  String backupImportPrivateSkippedCount(int count) {
    return '私密区域未解锁，跳过 $count 条';
  }

  @override
  String get backupImportPickerUnavailable => '此设备没有可用的文件选择器，无法选择备份文件';

  @override
  String get backupImportTooLarge => '备份文件超过大小限制';

  @override
  String get backupImportUnreadable => '备份文件无法读取';

  @override
  String get backupImportUnrecognized => '无法识别的备份格式';

  @override
  String get backupImportCorrupt => '备份文件已损坏';

  @override
  String get backupImportUnsupportedVersion => '暂不支持该备份版本';

  @override
  String get backupImportKeyUnavailable => '缺少解密密钥，未读取加密内容';

  @override
  String get backupImportUndecryptable => '备份内容无法解密';

  @override
  String get backupImportReasonMissingFields => '部分记录缺少名称或线路，未导入';

  @override
  String get backupImportReasonInvalid => '记录配置无效，未导入';

  @override
  String get backupImportReasonUnsupportedOptions => '包含无法表达的连接选项，未导入';

  @override
  String get backupImportReasonAccessRevoked => '导入期间权限或区域已变更，未导入';

  @override
  String get backupImportReasonPersistence => '保存失败，未导入';

  @override
  String get backupImportReasonRollback => '存储状态不确定，已停止后续写入';

  @override
  String get updateCheck => '检查更新';

  @override
  String get updateChecking => '正在检查更新…';

  @override
  String get updateCheckFailed => '暂时无法检查更新，请检查网络后重试。';

  @override
  String updateAvailable(String version) {
    return '发现新版本 $version';
  }

  @override
  String get updateCurrent => '当前已是最新版本';

  @override
  String get updateOpenRelease => '打开 Release 页';

  @override
  String get updateNotes => '更新内容';

  @override
  String get updateOpenFailed => '无法打开 Release 页，请确认已安装浏览器后重试。';

  @override
  String get updateDownload => '应用内下载';

  @override
  String get updateCancelDownload => '取消下载';

  @override
  String get updateNoPackage => '没有适用于当前系统及架构的安装包。可打开 Release 页查看。';

  @override
  String get updateTimeout => '检查更新超时，请稍后重试。';

  @override
  String get updateRateLimited => '更新服务请求过于频繁，请稍后重试。';

  @override
  String get updateNoRelease => '暂时没有可用的正式发布，请稍后重试。';

  @override
  String get updateInvalidResponse => '更新信息无效，无法确认是否有新版。请稍后重试。';

  @override
  String updatePackageVersion(String version) {
    return '安装包版本 $version';
  }

  @override
  String updateDownloadingUnknown(String received) {
    return '正在下载 · 已下载 $received';
  }

  @override
  String updateDownloading(String received, String total, int percent) {
    return '正在下载 $percent% · $received / $total';
  }

  @override
  String get updateVerifying => '正在校验安装包…';

  @override
  String get updateReady => '安装包已通过完整性校验，可继续安装。';

  @override
  String get updateCancelled => '下载已取消，可重新下载。';

  @override
  String get updateChecksumFailed => '无法通过安装包完整性校验，已禁止安装。请重新下载或打开 Release 页。';

  @override
  String get updateVerificationUnavailable =>
      '无法获取校验文件，无法完成安装包完整性校验，已禁止安装。请重试或打开 Release 页。';

  @override
  String get updateDiskFailed => '无法保存安装包，请检查剩余存储空间及目录权限后重试。';

  @override
  String get updateDownloadTimeout => '下载超时，请重试或打开 Release 页。';

  @override
  String get updateUnsafePackage => '安装包来源不符合官方发布规则，已停止下载。可打开 Release 页。';

  @override
  String get updateDownloadFailed => '下载失败，请检查网络后重试，或打开 Release 页。';

  @override
  String get updateInstall => '继续安装';

  @override
  String get updateInstalling => '正在交给系统处理…';

  @override
  String get updateWindowsGuide =>
      '继续后将打开 Windows 安装程序，请按系统提示确认。如需退出应用，请先结束播放，再通过窗口关闭按钮退出后继续安装。';

  @override
  String get updateMacGuide =>
      '继续后请选择安装包保存位置，打开 DMG，将应用拖入“应用程序”并确认替换。如需退出，请先结束播放并正常关闭应用。';

  @override
  String get updateLinuxGuide =>
      '继续后将打开 DEB 安装包，请按软件安装器提示操作。若未能打开，可在文件管理器中找到下方本地文件，使用系统的软件安装器安装。';

  @override
  String get updateAndroidGuide =>
      '继续后将打开系统安装页面，请按提示完成。如需允许安装来源，请先授权，再返回此处重试安装。';

  @override
  String get updateFinishPlayback => '请先结束并退出播放，再继续安装更新。';

  @override
  String get updateHandedOff => '已交给系统安装流程。请按系统提示完成，重新打开应用后确认版本。';

  @override
  String get updatePermissionRequired => '尚未允许此应用安装更新，请打开来源授权设置。';

  @override
  String get updateAllowSource => '打开来源授权设置';

  @override
  String get updatePermissionOpened => '已打开来源授权设置。允许后返回此处，再点击“继续安装”；尚未开始安装。';

  @override
  String get updatePermissionDenied => '系统未授予所需权限。请确认权限后重试。';

  @override
  String get updateInstallCancelled => '已取消系统操作，尚未确认更新完成。可再次尝试。';

  @override
  String get updateIncompatible => '安装包与当前应用身份、签名或版本不兼容，无法安装。可打开 Release 页查看。';

  @override
  String get updateInstallFailed => '无法启动系统安装流程。请按平台指引处理或重试，也可打开 Release 页。';

  @override
  String updateLocalPackage(String path) {
    return '本地安装包：$path';
  }

  @override
  String get updateReminderTitle => '应用更新';

  @override
  String get updateLater => '稍后处理';

  @override
  String get serversTitle => '服务器';

  @override
  String get serversSearch => '搜索名称或地址';

  @override
  String get serversEmptyTitle => '添加你的第一台服务器';

  @override
  String get serversEmptyHint => '连接 Emby、Jellyfin 或 Plex，开始观看。';

  @override
  String get serversNoResults => '没有找到服务器';

  @override
  String get serversNoResultsHint => '换个关键词，或清除搜索。';

  @override
  String get serversSearchResults => '搜索结果';

  @override
  String get serversConnectionError => '连接失败';

  @override
  String get serversClearSearch => '清除搜索';

  @override
  String get serversMore => '更多操作';

  @override
  String get serversEdit => '编辑服务器';

  @override
  String get serversRemove => '移除服务器';

  @override
  String get serversRemoveHint => '只移除此设备上的配置和登录，不会删除服务器上的内容。';

  @override
  String get serversCurrentImpact => '这是当前使用的服务器。继续将结束这台服务器的当前连接。';

  @override
  String get serversUp => '上移';

  @override
  String get serversDown => '下移';

  @override
  String get serversCurrent => '当前使用';

  @override
  String get serversLocked => '已锁定';

  @override
  String get serversEnter => '进入服务器';

  @override
  String get serversLines => '连接线路';

  @override
  String get serversAutomatic => '自动选择';

  @override
  String get serversAutomaticHint => '连接失败时尝试同一服务器的备用线路。';

  @override
  String get serversFixedHint => '选中具体线路后固定使用，失败时由你决定是否更换。';

  @override
  String get serversActualLine => '正在使用';

  @override
  String get serversNotChecked => '尚未检查';

  @override
  String get serversCheck => '检查连接';

  @override
  String get serversCheckPassed => '连接正常';

  @override
  String get serversCheckFailed => '连接失败，可重试或换线';

  @override
  String get serversCheckIdentity => '这个地址属于另一台服务器';

  @override
  String get serversCheckLogin => '请重新登录';

  @override
  String get serversCheckUnknown => '检查未完成';

  @override
  String get serversCheckedAt => '检查于';

  @override
  String get serversSave => '保存';

  @override
  String get serversCancel => '取消';

  @override
  String get serversBack => '返回';

  @override
  String get serversName => '显示名称';

  @override
  String get serversIcon => '图标';

  @override
  String get serversIconDefault => '服务默认';

  @override
  String get serversIconHome => '家';

  @override
  String get serversIconCinema => '影院';

  @override
  String get serversIconCloud => '云端';

  @override
  String get serversAccount => '服务器账号';

  @override
  String get serversReauthorize => '重新登录 / 更换账号';

  @override
  String get serversSignOut => '退出此账号';

  @override
  String get serversSignOutHint => '保留服务器配置，下次进入时重新登录。';

  @override
  String get serversLinesHint => '同一服务器的不同地址。按顺序使用备用线路。';

  @override
  String get serversLineName => '线路名称（可选）';

  @override
  String get serversLineAddress => '服务器地址';

  @override
  String get serversLineAdd => '添加线路';

  @override
  String get serversLineEdit => '编辑线路';

  @override
  String get serversLineRemove => '移除这条线路';

  @override
  String get serversLineLast => '至少保留一条线路';

  @override
  String get serversLineDraftHint => '返回后继续编辑，点击服务器表单的“保存”才生效。';

  @override
  String get serversAdvanced => '高级设置';

  @override
  String get serversPassword => '进入时需要密码';

  @override
  String get serversPasswordHint => '本机进入密码；服务器账号保持登录。';

  @override
  String get serversPasswordSet => '设置进入密码';

  @override
  String get serversPasswordChange => '修改进入密码';

  @override
  String get serversPasswordDisable => '关闭进入密码';

  @override
  String get serversPasswordOld => '原进入密码';

  @override
  String get serversPasswordNew => '新进入密码';

  @override
  String get serversPasswordConfirm => '再次输入密码';

  @override
  String get serversPasswordInput => '本机进入密码';

  @override
  String get serversPasswordPrompt => '输入此服务器的本机进入密码，继续到原来的页面。';

  @override
  String get serversPasswordWrong => '密码不正确。';

  @override
  String get serversPasswordUnavailable => '无法读取进入密码。可返回后移除此本机条目，再正常登录添加。';

  @override
  String get serversPasswordMismatch => '两次密码不一致';

  @override
  String get serversPasswordRequired => '请输入 1–1024 个字符的密码';

  @override
  String get serversPasswordSaveFailed => '密码未保存。请检查原密码，稍后重试。';

  @override
  String get serversPasswordPending => '将在保存服务器时更新';

  @override
  String get serversConnectionImpact => '你正在修改当前连接。保存成功后将重新连接；取消会保留原连接。';

  @override
  String get serversSaveFailed => '未保存，请检查输入或连接后重试。';

  @override
  String get serversInvalidDraft => '请填写服务器名称和有效地址；线路地址不能重复。';

  @override
  String get serversAddTitle => '添加服务器';

  @override
  String get serversPaste => '粘贴导入';

  @override
  String get serversPasteHint => '仅在你点击后读取剪贴板。确认识别结果后再登录。';

  @override
  String get serversPasteText => '粘贴服务器信息';

  @override
  String get serversParse => '识别并预览';

  @override
  String get serversPasteGroups => '识别到多个账号，请选择要添加的一组';

  @override
  String get serversPasteIncomplete => '请检查并补全信息。每次只添加你选择的一组。';

  @override
  String get serversPasteUnknown => '未识别到服务器信息，可以修改原文后重试。';

  @override
  String get serversPasteExtra => '备用线路（每行一个地址）';

  @override
  String get serversPasteName => '名称（可选）';

  @override
  String get serversPastePreview => '确认服务器信息';

  @override
  String get serversContinue => '继续';

  @override
  String get serversEntryPlaybackImpact => '进入另一台服务器后，当前播放将结束，原服务器会重新锁定。';

  @override
  String get serversBusy => '正在连接…';

  @override
  String get serversConnectionFailed => '连接失败，原连接已保留。请检查线路或重新登录。';

  @override
  String get serversRetry => '重试';

  @override
  String get serversDone => '完成';

  @override
  String get serversChangeAccountHint => '重新授权成功后才替换账号；更换账号会结束原账号的播放。取消保留原登录。';

  @override
  String get serversPasswordOff => '未启用';

  @override
  String get serversPasswordOn => '已启用';

  @override
  String get serversImportFile => '从备份文件导入';

  @override
  String get serversSelectType => '选择服务类型';

  @override
  String get serversDismiss => '关闭';

  @override
  String get serversPasteGroup => '账号组';

  @override
  String get serversAddressHidden => '解锁后查看连接信息';

  @override
  String get serversNoAccount => '尚未登录';

  @override
  String get serversActionFailed => '操作未完成，请稍后重试。';

  @override
  String get serversPasswordBackoff => '密码错误。请稍后重试，或返回选择其他服务器。';

  @override
  String get serversRemotePassword => '修改服务器账号密码';

  @override
  String get serversBasic => '基本信息';

  @override
  String serversPasswordRetryAfter(int seconds) {
    return '$seconds 秒后可重试';
  }

  @override
  String get playbackReconnecting => '正在重新连接…';

  @override
  String get playbackTryingAlternative => '正在尝试备用线路…';

  @override
  String get playbackRecoveryStopped => '连接尚未恢复';

  @override
  String get playbackRecoveryPositionKept => '观看位置已保留，你可以重试或选择其他线路。';

  @override
  String get playbackChooseLine => '选择线路';

  @override
  String get playbackLineFailureHint => '线路未切换成功。请重试或选择其他线路。';

  @override
  String get playbackSwitchNeedsChoice => '继续前，请确认播放选择';

  @override
  String get playbackPositionUnavailable => '这个版本无法从原观看位置继续。可以从头播放，或取消切换。';

  @override
  String get playbackTimelineUncertain => '两个版本的时长或片段可能不同，请确认是否沿用原观看位置。';

  @override
  String get playbackAudioUnavailable => '原音轨不可用，请选择其他音轨。';

  @override
  String get playbackSubtitleUnavailable => '原字幕不可用，请选择其他字幕，或明确关闭字幕。';

  @override
  String get playbackUseDefaultAudio => '使用此版本的默认音轨';

  @override
  String get playbackContinueWithoutSubtitles => '关闭字幕继续';

  @override
  String get playbackStartFromBeginning => '从头播放';

  @override
  String get playbackContinueAtPosition => '沿用原观看位置';

  @override
  String get playbackCertificateStopped => '无法建立安全连接';

  @override
  String get playbackPermissionStopped => '当前账号没有播放权限';

  @override
  String get playbackRateLimited => '服务器暂时限制请求';

  @override
  String get playbackRetryAfterRepair => '修复后重试';

  @override
  String get playbackRetryAfterPermission => '权限恢复后重试';

  @override
  String playbackRetryAfter(int seconds) {
    return '$seconds 秒后可重试';
  }

  @override
  String get playbackLinePending => '正在连接，成功后才会保存选择';

  @override
  String get playbackLineFixed => '固定线路';

  @override
  String playbackLineActual(String line) {
    return '正在使用：$line';
  }

  @override
  String get sourceSelectionAction => '选择影片来源';

  @override
  String get sourceSelectionEmpty => '暂未找到其他来源';

  @override
  String get sourceSelectionRetry => '部分来源加载失败，重试';

  @override
  String get sourceSelectionMore => '继续查找';

  @override
  String get sourceSelectionCheckDetails => '请核对影片详情';

  @override
  String get sourceSelectionHint => '打开对应详情，不会直接播放。';

  @override
  String sourceSelectionFound(int count) {
    return '找到 $count 个来源';
  }

  @override
  String get sourceSelectionSearching => '正在其他服务器上查找';

  @override
  String get sourceSelectionFilterAny => '不限';

  @override
  String get sourceSelectionResolution => '清晰度';

  @override
  String get sourceSelectionRange => '动态范围';

  @override
  String get sourceSelectionVideo => '编码';

  @override
  String get sourceSelectionSubtitle => '字幕';

  @override
  String get sourceSelectionSubtitleChinese => '中字';

  @override
  String get sourceSelectionSubtitleEnglish => '英字';

  @override
  String get sourceSelectionSubtitleExternal => '外挂';

  @override
  String get sourceSelectionSubtitlePresent => '有字幕';

  @override
  String get sourceSelectionSubtitleNone => '无字幕';

  @override
  String get sourceSelectionSound => '声音';

  @override
  String get sourceSelectionNoMatch => '没有符合条件的来源';

  @override
  String get sourceSelectionClearFilters => '清除筛选';

  @override
  String get sourceSelectionBestBitrate => '最高码率';

  @override
  String get sourceSelectionClearest => '最清晰';

  @override
  String get sourceSelectionWatchedToday => '今天看过';

  @override
  String get sourceSelectionWatchedYesterday => '昨天看过';

  @override
  String sourceSelectionWatchedDays(int days) {
    return '$days 天前看过';
  }

  @override
  String sourceSelectionEpisodeCount(int count) {
    return '共 $count 集';
  }

  @override
  String get sourceSelectionPasswordTitle => '输入访问密码';

  @override
  String get sourceSelectionPasswordPrompt => '输入这台服务器的本机密码，查看可选来源。';

  @override
  String get sourceSelectionUnlock => '解锁';

  @override
  String get sourceSelectionUnavailable => '暂时无法加载影片来源，请重试。';

  @override
  String get updateReminderSubtitle => '发现可用更新，可直接在应用内下载校验并安装';

  @override
  String updateVersionTransition(String current, String target) {
    return '当前 v$current → 最新 v$target';
  }

  @override
  String get updateCurrentBadge => '已是最新';

  @override
  String get updateNewBadge => '可更新';

  @override
  String get updateIgnoreVersion => '此版本不再提醒';

  @override
  String get updateUnignoreVersion => '恢复此版本提醒';

  @override
  String updateIgnoredBadge(String version) {
    return '已忽略 v$version 提醒';
  }

  @override
  String get updateDisableReminder => '不再自动提醒';

  @override
  String get updateAutoReminderTitle => '启动时自动提醒更新';

  @override
  String get updateAutoReminderSubtitle => '发现新版本时自动弹窗提醒，关闭后仍可在此处手动检查';

  @override
  String get settingsWebDavSection => '备份与同步';

  @override
  String get settingsWebDavSectionSummary => '手动备份完整配置到自备 WebDAV，换机可一键恢复';

  @override
  String get settingsWebDavAddress => '服务器地址';

  @override
  String get settingsWebDavAddressHint => '例如 https://dav.example.com:5006';

  @override
  String get settingsWebDavUsername => '账号';

  @override
  String get settingsWebDavPassword => '密码';

  @override
  String get settingsWebDavPasswordShow => '显示密码';

  @override
  String get settingsWebDavPasswordHide => '隐藏密码';

  @override
  String get settingsWebDavDirectory => '备份目录';

  @override
  String get settingsWebDavDirectoryHint => '远端存放备份文件的目录，留空使用根目录';

  @override
  String get settingsWebDavTestConnection => '测试连接';

  @override
  String get settingsWebDavConnectionOk => '连接成功';

  @override
  String get settingsWebDavCredentialError => '账号或密码错误';

  @override
  String get settingsWebDavDirectoryMissing => '备份目录不存在，请先创建或修改目录';

  @override
  String settingsWebDavHttpError(int status) {
    return '服务器返回错误（HTTP $status）';
  }

  @override
  String get settingsWebDavUnreachable => '无法连接服务器，请检查地址与网络';

  @override
  String get settingsWebDavBackup => '立即备份';

  @override
  String settingsWebDavBackupDone(String time) {
    return '备份完成 · $time';
  }

  @override
  String get settingsWebDavLocalConfigCorrupt => '本地配置文件损坏，本次操作已取消';

  @override
  String get settingsWebDavBackupFailed => '备份失败，请重试';

  @override
  String get settingsWebDavRestore => '从备份恢复';

  @override
  String get settingsWebDavRestored => '已恢复';

  @override
  String get settingsWebDavNoBackup => '服务器上还没有备份文件';

  @override
  String get settingsWebDavRestoreRejected => '备份文件校验未通过，本地数据未改动';

  @override
  String get settingsWebDavRestoreFailed => '恢复失败，请重试';

  @override
  String get settingsWebDavNotConfigured => '请先填写 WebDAV 服务器地址';

  @override
  String get settingsWebDavSaveFailed => '配置保存失败，请重试';

  @override
  String get serversSubtitle => '选择要观看的服务器';

  @override
  String serversCount(int count) {
    return '共 $count 台';
  }

  @override
  String get serversSectionAll => '全部服务器';

  @override
  String get serversSwitchLine => '换条线路';

  @override
  String get serversLineSubtitle => '同一台服务器的不同地址';

  @override
  String serversLineCount(int count) {
    return '$count 条线路';
  }

  @override
  String get serversLineActual => '当前';

  @override
  String get serversLineDetails => '线路详情';

  @override
  String get serversRecommend => '推荐';

  @override
  String get serversEditorSubtitle => '名称、账号、线路与进入保护';

  @override
  String get serversAddSubtitle => '登录后即可直接观看';

  @override
  String get serversLoginAction => '重新登录';

  @override
  String get serversCurrentLine => '当前线路';

  @override
  String get serversBackupLine => '备用线路';

  @override
  String get serversAccountStatus => '账号状态';

  @override
  String get serversLoggedIn => '已登录';

  @override
  String get serversProtection => '进入保护';

  @override
  String get serversProtectionSummary => '只在这台设备上生效，不影响服务器账号';

  @override
  String get serversBasicSummary => '名称和图标用于在列表中辨认这台服务器';

  @override
  String get serversLinesSummary => '按顺序尝试；固定线路失败时由你决定是否切换';

  @override
  String get serversAdvancedSummary => 'User-Agent 等少用配置';

  @override
  String get serversLockedHint => '已锁定 · 输入进入密码后可用';

  @override
  String get serversLineFixedSection => '指定线路';

  @override
  String get serversLineAutoSection => '选线方式';

  @override
  String get serversRemoveTitle => '移除这台服务器？';

  @override
  String get serversPasteCardHint => '复制了服务器信息？一键识别地址、账号和多条线路';

  @override
  String get serversUnlockTitle => '输入进入密码';

  @override
  String get serversEnterOtherTitle => '切换到这台服务器？';

  @override
  String get serversSignOutTitle => '退出这个账号？';

  @override
  String get serversImpactTitle => '修改当前连接？';

  @override
  String get serversAccountSection => '账号';

  @override
  String get serversCheckingNow => '正在检查…';

  @override
  String get serversFixedShort => '固定';

  @override
  String get serversMoreOptions => '更多方式';

  @override
  String serversHubSubtitle(int count) {
    return '$count 台服务器 · 点按进入';
  }

  @override
  String get serversAddShort => '添加';
}
