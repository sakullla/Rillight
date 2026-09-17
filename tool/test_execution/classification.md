# 集成标签归属

`integration` 仅标记泵完整应用或完整功能页的 widget 用例；纯逻辑、假进程和局部 widget 仍由默认 `flutter test` 执行。2026-09-18 测试组织调整保留原 408 项及其全部断言，原 65 个集成标签用例按下表纠正为 30 个完整页面、32 个纯单元和 3 个局部 widget；另补上此前漏标的 SettingsPage 3 项，集成子集共 33 项。表中保留迁移前的文件名便于追溯，对应当前 `_cases.dart` 文件。

| 原文件 | 原用例 | 归属 |
| --- | --- | --- |
| `app_shell_test.dart` | app shell integration unsigned connect shell, theme, and deep link | 完整页面 / integration |
| `auth/connect_page_test.dart` | wrong password, successful login, logout, and saved server fill | 完整页面 / integration |
| `catalog/catalog_browse_test.dart` | home, library details, mark played, and search share one logged-in pump | 完整页面 / integration |
| `app_shell_test.dart` | AppErrorView shows failure message and retry | 局部 widget / full |
| `app_shell_test.dart` | PosterPlaceholder remains available after image failure | 局部 widget / full |
| `app_shell_test.dart` | app shell logged-in logged-in shell is full-width and switching servers reloads home | 完整页面 / integration |
| `app_shell_test.dart` | app shell logged-in top bar switches home, library, search overlay, and detail back | 完整页面 / integration |
| `auth/connect_page_test.dart` | two lines can be selected and a failed line stays on connect | 完整页面 / integration |
| `catalog/item_detail_test.dart` | episode card play button starts playback | 完整页面 / integration |
| `auth/connect_page_test.dart` | path and User-Agent under 更多 are composed into the saved line | 完整页面 / integration |
| `app_shell_test.dart` | app shell logged-in top bar keeps five libraries and puts the rest in overflow | 完整页面 / integration |
| `catalog/library_filter_test.dart` | filter confirm, type, and year share one logged-in pump | 完整页面 / integration |
| `catalog/item_detail_test.dart` | episode card check marks the episode played | 完整页面 / integration |
| `catalog/catalog_browse_test.dart` | grid column max extent is at least 180/200/220 | 纯单元 / full |
| `catalog/shelf_grid_scroll_rebuild_test.dart` | scrolling the poster wall does not rebuild live cards | 完整页面 / integration |
| `catalog/item_detail_test.dart` | load more appends the next episode window without duplicates | 完整页面 / integration |
| `catalog/item_detail_test.dart` | view series from an episode opens that season | 完整页面 / integration |
| `catalog/item_detail_test.dart` | episode detail request asks for the People field | 完整页面 / integration |
| `home/home_page_test.dart` | home renders without LiquidGlass and refresh reloads the resume shelf | 完整页面 / integration |
| `home/home_page_test.dart` | refresh button falls back to the first visible shelf without resume | 完整页面 / integration |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost a delayed detail command cannot route after another player opens | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost close during spawn cannot publish the late player window | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost opening a second item requests close, kills on timeout, and resends Stopped once from the snapshot before deleting it | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost cancelled late spawn reconciles after exit and before release when closing | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost cancelled late spawn reconciles after exit and before release when reopening | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost cancelled late spawn retains failed Stopped snapshot | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost cancelled late spawn retains foreign Stopped snapshot | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost watch delivers an open-item command to the main window | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost graceful close skips kill and tolerates a stale snapshot | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost no snapshot means nothing is resent | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost snapshot from another server or user is not resent | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost an unexpectedly exited process is detected, cleared and its Stopped is resent | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost a failed resend keeps the snapshot and emits progressSyncFailed | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost overlapping close then open keeps the new pid watched | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost close joins watcher reconcile before logout | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | DesktopPlayerWindowHost logout without a prior close cannot resend (session gone) | 纯单元 / full |
| `player/desktop_player_window_host_test.dart` | main window integration a failed resend after the process vanished shows progressSyncFailedMain | 完整页面 / integration |
| `home/home_page_test.dart` | refresh button falls back to libraries when media rows are hidden | 完整页面 / integration |
| `home/home_page_test.dart` | a home row shows error and retry after quiet retries are exhausted | 完整页面 / integration |
| `player/desktop_player_window_host_test.dart` | main window integration logout closes the player window before auth.logout | 完整页面 / integration |
| `player/player_controls_test.dart` | failed subtitle selection shows a dismissible player banner | 完整页面 / integration |
| `player/desktop_player_window_host_test.dart` | main window integration switching servers closes the player window before switchTo | 完整页面 / integration |
| `player/desktop_player_window_host_test.dart` | main window integration MainWindowCloseGuard closes the player before destroying | 局部 widget / full |
| `player/player_window_test.dart` | closing the player window keeps AuthController and the browse app | 完整页面 / integration |
| `player/player_controls_test.dart` | saved progress resumes without a continue-or-restart prompt | 完整页面 / integration |
| `player/player_controls_test.dart` | movie end shows replay card instead of a blank frame | 完整页面 / integration |
| `player/player_controls_test.dart` | pausing on the last frame without EOF does not end playback | 完整页面 / integration |
| `player/player_controls_test.dart` | view series from the ended card opens series detail | 完整页面 / integration |
| `player/player_window_test.dart` | player window options hide the title bar without embedding playback | 纯单元 / full |
| `player/player_window_test.dart` | player window create failure shows the original error and does not play | 完整页面 / integration |
| `player/player_controls_test.dart` | openEndedSeries opens series detail instead of playing the series | 纯单元 / full |
| `player/player_controls_test.dart` | openEndedSeries without a detail callback closes instead of playing | 纯单元 / full |
| `player/player_controls_test.dart` | episode pause at end offers the next episode without a completed event | 纯单元 / full |
| `player/player_controls_test.dart` | next episode keeps subtitle language and bitrate | 纯单元 / full |
| `player/player_controls_test.dart` | bitrate-only memory does not turn subtitles off on the next episode | 纯单元 / full |
| `player/player_controls_test.dart` | repeated progress failures keep the banner until a report succeeds | 完整页面 / integration |
| `player/player_controls_test.dart` | close waits for Stopped before onClose and reports the last position | 纯单元 / full |
| `player/player_controls_test.dart` | close gives up on a hanging Stopped at its deadline and keeps the snapshot | 纯单元 / full |
| `player/player_controls_test.dart` | close waits for an in-flight Stopped started by setMaxBitrate | 纯单元 / full |
| `player/player_controls_test.dart` | a second close joins the first and fires onClose once | 纯单元 / full |
| `player/player_controls_test.dart` | close waits for snapshot delete before onClose | 纯单元 / full |
| `player/player_controls_test.dart` | volume percent maps linearly to mpv volume | 纯单元 / full |
| `player/player_controls_test.dart` | buffer fraction is cache end over duration | 纯单元 / full |
| `player/player_controls_test.dart` | episode list offset jumps by index without walking prior rows | 纯单元 / full |
| `player/player_controls_test.dart` | episode window start fills a page around the current index | 纯单元 / full |

补入 `settings_page_cases.dart` 的完整页面用例：

- shows the stored settings
- changing the disk cache limit persists and echoes
- restore defaults writes explicit defaults
