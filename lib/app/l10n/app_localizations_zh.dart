// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appName => '灯川 Rillight';

  @override
  String get retry => '重试';

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
  String get extraLineAddress => '线路地址';

  @override
  String get searchServers => '搜索服务器';

  @override
  String lineCount(int count) {
    return '$count 条线路';
  }

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
  String get errorSessionExpired => '会话已失效，请重新登录';

  @override
  String get errorUnknown => '连接失败';

  @override
  String get home => '首页';

  @override
  String get libraries => '片库';

  @override
  String get customizeNav => '自定义导航';

  @override
  String customizeNavHint(int count) {
    return '最多勾选 $count 个。顶栏放不下的会进「更多」。未勾选的不出现在导航、更多和首页片库。';
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
  String get similarRow => '更多类似';

  @override
  String get episodesRow => '集';

  @override
  String get episodesLoadMore => '加载更多';

  @override
  String get sortBy => '排序';

  @override
  String get libraryFilter => '筛选';

  @override
  String get libraryFilterClear => '清除筛选';

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
  String get play => '播放';

  @override
  String get details => '详情';

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
  String get qualityAuto => '自动';

  @override
  String qualityMbps(int mbps) {
    return '$mbps Mbps';
  }

  @override
  String get chapters => '章节';

  @override
  String get mediaSource => '片源';

  @override
  String get audioTrack => '音轨';

  @override
  String get subtitleTrack => '字幕';

  @override
  String get subtitleOff => '关闭字幕';

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
  String get playerLoading => '正在打开播放…';

  @override
  String get settings => '设置';

  @override
  String get settingsPlayback => '播放';

  @override
  String get settingsDiskCacheLimit => '磁盘缓冲上限';

  @override
  String get settingsDiskCacheLimitHint => '限制本地缓冲占用';

  @override
  String get settingsHardwareDecoding => '硬件解码';

  @override
  String get settingsHardwareDecodingHint => '用显卡解码，降低 CPU 占用';

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
  String get skipSettings => '片头片尾';

  @override
  String get skipManualOff => '关闭手动跳过';

  @override
  String skipIntroSeconds(int seconds) {
    return '片头 $seconds 秒';
  }

  @override
  String skipOutroSeconds(int seconds) {
    return '片尾 $seconds 秒';
  }

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
  String get danmakuSearch => '手动搜索';

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
  String get danmakuEpisodes => '分集';
}
