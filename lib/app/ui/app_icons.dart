import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';

/// 三端共用的圆角 Material Symbols。
///
/// 默认用 [filled]。导航目的地和开关未选中用 [outline]，选中用 [filled]，
/// 图形本身不变。播放、暂停、搜索、筛选、设置、弹幕、返回、画质、
/// 实际输出、媒体库和聚合的图形在这里固定。
abstract final class AppIcons {
  static const double filled = 1;
  static const double outline = 0;

  /// 放大镜。
  static const IconData search = Symbols.search_rounded;

  /// 漏斗。片库筛选只用这一个图形。
  static const IconData filter = Symbols.filter_alt_rounded;

  /// 齿轮。打开设置只用这一个图形。
  static const IconData settings = Symbols.settings_rounded;

  /// 对话气泡。弹幕只用这一个图形。
  static const IconData danmaku = Symbols.chat_rounded;

  /// 指向后退方向的箭头。
  static const IconData back = Symbols.arrow_back_rounded;

  /// 清晰度标记。画质只用这一个图形，和 [output] 不同。
  static const IconData quality = Symbols.hd_rounded;

  /// 显示器。实际输出只用这一个图形，和 [quality] 不同。
  static const IconData output = Symbols.monitor_rounded;

  /// 影片合集。媒体库只用这一个图形，和 [aggregation] 不同。
  static const IconData library = Symbols.video_library_rounded;

  /// 内容合集。聚合只用这一个图形，和 [library] 不同。
  static const IconData aggregation = Symbols.collections_rounded;

  /// 播放三角。
  static const IconData play = Symbols.play_arrow_rounded;

  /// 暂停双竖线。
  static const IconData pause = Symbols.pause_rounded;

  static const IconData replay10 = Symbols.replay_10_rounded;
  static const IconData forward10 = Symbols.forward_10_rounded;
  static const IconData skipNext = Symbols.skip_next_rounded;

  /// 上一集。和 [skipNext] 成对，图形本身不变。
  static const IconData skipPrevious = Symbols.skip_previous_rounded;

  /// 心形。收藏未选中为线框，选中为同一图形的实心。
  static const IconData favorite = Symbols.favorite_rounded;
  static const IconData fastForward = Symbols.fast_forward_rounded;
  static const IconData replay = Symbols.replay_rounded;
  static const IconData refresh = Symbols.refresh_rounded;

  static const IconData close = Symbols.close_rounded;
  static const IconData check = Symbols.check_rounded;
  static const IconData checkCircle = Symbols.check_circle_rounded;
  static const IconData add = Symbols.add_rounded;
  static const IconData addCircle = Symbols.add_circle_rounded;
  static const IconData remove = Symbols.remove_rounded;
  static const IconData chevronRight = Symbols.chevron_right_rounded;
  static const IconData chevronDown = Symbols.expand_more_rounded;
  static const IconData chevronUp = Symbols.expand_less_rounded;
  static const IconData forward = Symbols.arrow_forward_rounded;
  static const IconData arrowUp = Symbols.arrow_upward_rounded;

  static const IconData home = Symbols.home_rounded;
  static const IconData person = Symbols.person_rounded;
  static const IconData group = Symbols.group_rounded;
  static const IconData account = Symbols.account_circle_rounded;
  static const IconData badge = Symbols.badge_rounded;
  static const IconData lock = Symbols.lock_rounded;
  static const IconData lockOpen = Symbols.lock_open_rounded;
  static const IconData shield = Symbols.shield_rounded;
  static const IconData link = Symbols.link_rounded;
  static const IconData edit = Symbols.edit_rounded;
  static const IconData delete = Symbols.delete_rounded;
  static const IconData download = Symbols.download_rounded;
  static const IconData logout = Symbols.logout_rounded;

  /// 眼睛。密码或令牌是否可见只用这一个图形，未显示为线框，显示为实心。
  static const IconData visibility = Symbols.visibility_rounded;
  static const IconData error = Symbols.error_rounded;

  /// 禁止标记。不支持的服务类型计数只用这一个图形，片库筛选仍用 [filter]。
  static const IconData block = Symbols.block_rounded;
  static const IconData info = Symbols.info_rounded;
  static const IconData star = Symbols.star_rounded;
  static const IconData photo = Symbols.image_rounded;
  static const IconData photoLibrary = Symbols.photo_library_rounded;
  static const IconData empty = Symbols.inbox_rounded;
  static const IconData movie = Symbols.movie_rounded;

  /// 条目列表。选集只用这一个图形，和 [playlist] 不同。
  static const IconData episodes = Symbols.format_list_bulleted_rounded;
  static const IconData series = Symbols.tv_rounded;
  static const IconData mediaSource = Symbols.video_file_rounded;
  static const IconData music = Symbols.music_note_rounded;
  static const IconData musicVideo = Symbols.music_video_rounded;
  static const IconData liveTv = Symbols.live_tv_rounded;
  static const IconData boxSet = Symbols.folder_special_rounded;

  /// 播放列表。片库播放列表只用这一个图形，和 [episodes] 不同。
  static const IconData playlist = Symbols.playlist_play_rounded;

  /// 服务器。管理服务器只用这一个图形，设置仍用 [settings]。
  static const IconData server = Symbols.dns_rounded;
  static const IconData lan = Symbols.lan_rounded;
  static const IconData wifi = Symbols.wifi_rounded;
  static const IconData wifiOff = Symbols.wifi_off_rounded;
  static const IconData speed = Symbols.speed_rounded;
  static const IconData subtitles = Symbols.closed_caption_rounded;

  /// 摄像机。片源里的视频轨只用这一个图形，影片库仍用 [movie]，片源文件仍用 [mediaSource]。
  static const IconData video = Symbols.videocam_rounded;

  /// 四向展开。全屏开关只用这一个图形，未全屏为线框，全屏为实心。
  static const IconData fullscreen = Symbols.fullscreen_rounded;
  static const IconData volumeUp = Symbols.volume_up_rounded;
  static const IconData volumeDown = Symbols.volume_down_rounded;
  static const IconData volumeOff = Symbols.volume_off_rounded;
  static const IconData pin = Symbols.keep_rounded;
  static const IconData pictureInPicture =
      Symbols.picture_in_picture_alt_rounded;
  static const IconData aspectRatio = Symbols.aspect_ratio_rounded;
  static const IconData brightness = Symbols.brightness_high_rounded;
  static const IconData schedule = Symbols.schedule_rounded;
  static const IconData hourglass = Symbols.hourglass_empty_rounded;
  static const IconData circle = Symbols.circle_rounded;
  static const IconData cloud = Symbols.cloud_rounded;
  static const IconData qrCode = Symbols.qr_code_rounded;
  static const IconData appearance = Symbols.contrast_rounded;
  static const IconData lightMode = Symbols.light_mode_rounded;
  static const IconData darkMode = Symbols.dark_mode_rounded;
  static const IconData playbackSection = Symbols.play_circle_rounded;
  static const IconData tune = Symbols.tune_rounded;
  static const IconData nowPlaying = Symbols.graphic_eq_rounded;
  static const IconData route = Symbols.alt_route_rounded;
  static const IconData swap = Symbols.swap_horiz_rounded;
  static const IconData openInNew = Symbols.open_in_new_rounded;
  static const IconData bolt = Symbols.bolt_rounded;
  static const IconData copy = Symbols.content_copy_rounded;
  static const IconData tag = Symbols.tag_rounded;
  static const IconData globe = Symbols.public_rounded;

  /// 方框勾选。多选未选中为线框，选中为同一图形的实心。
  static const IconData checkbox = Symbols.check_box_rounded;
}
