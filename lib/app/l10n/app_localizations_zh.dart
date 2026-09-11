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
  String get connect => '连接';

  @override
  String get connecting => '正在连接…';

  @override
  String get logout => '退出登录';

  @override
  String get savedServers => '已保存的服务器';

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
  String get search => '搜索';

  @override
  String get searchHint => '搜索电影或剧集';

  @override
  String get searchEmptyQuery => '输入片名后搜索';

  @override
  String get searchNoResults => '没有结果';

  @override
  String get resumeRow => '继续观看';

  @override
  String get nextUpRow => '即将播放';

  @override
  String get latestMoviesRow => '最近添加的电影';

  @override
  String get latestSeriesRow => '最近添加的剧集';

  @override
  String get markPlayed => '标记已看';

  @override
  String get markUnplayed => '标记未看';

  @override
  String get overview => '简介';

  @override
  String get seasons => '季';

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
  String get pause => '暂停';

  @override
  String get resumePlay => '继续播放';

  @override
  String get playFromStart => '从头播放';

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
  String get qualityAuto => '自动';

  @override
  String qualityMbps(int mbps) {
    return '$mbps Mbps';
  }

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
  String get playbackFailed => '无法播放';

  @override
  String get noPlayableStream => '没有可播放的流';

  @override
  String get playerLoading => '正在打开播放…';
}
