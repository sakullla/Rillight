# 三端 UI/UX 重设计依据

参考用户提供的 `docs/test/` 手机详情、首页、片库和桌面筛选截图；这些本地图片不随代码打包。

## 信息与交互

- 手机采用独立的阅读字号、触控行高和默认贴底导航；保留用户已经选择的悬浮导航偏好。窄手机使用两列海报，较宽手机使用三列；标题可占两行，评分与季数分开呈现。
- Emby `Series.ChildCount` 是直接子项数量，应显示季数，不能当作全集数。分集继续显示季集编号。
- 加载页与成品共用 `PhoneDetailCaption`，保持头图、标题、元数据和主操作的布局一致；首页与片库骨架保留实际图片和文字区域的尺寸。
- 筛选采用分类导航、可搜索选项、已选摘要及固定的重置／应用区。选择先保存在草稿，取消不发查询；年份和流派支持多选。纯电影／剧集库不展示无效的混合类型切换。
- 手机以紧凑分类条进入选项，桌面和 TV 使用左右分栏；TV 仍保留可见焦点和独立遥控器操作。年份不再局限于首批海报出现的年份，流派通过 Emby `/Genres` 分页获取，失败可重试。
- 缓存范围只绘制已验证的媒体时间或独立的字节覆盖;手机 Slider 的主题顺序不再覆盖缓存轨道。网速采样不等待媒体索引计算,归零时仍保留已缓存区间。

## TV 沉浸化(2026-10)

- 导航改为 Netflix 2025 式顶部横向菜单:字标 + 图标胶囊(首页/片库/搜索/设置)+ 用户名。左右键在菜单间移动,下键进入面板并恢复面板上次焦点,面板顶部按上键经方向遍历回到菜单;返回键在非首页面板回落首页菜单。进入面板的按键由侧栏时代的右键改为下键。
- 首页 hero 全宽出血到导航栏下,文字恒白压 `AppScrim` 遮罩(顶带/左文字带/底带),继续观看行改 16:9 横版卡(进度条、已看角标、剧集名);片库面板改 16:9 艺术图大卡网格;详情页背图出血到屏顶,标题行带遮罩浮于其上;搜索条与筛选改胶囊;设置面板按账户与服务器/外观/服务器线路/其他分节。
- 导航栏非交互文本不拦截命中,hero 与内容在栏下出血时仍可点按;内容区不用 BackdropFilter(弱 TV GPU),只用渐变遮罩,聚焦卡仅一个 16blur 阴影。
- TV 浏览页保留浅色主题:导航渐变在浅色下用 surface 渐隐,hero 遮罩与文字不随主题变化。

### 联网查阅的来源(TV)

- [Netflix 2025 TV 体验](https://about.netflix.com/news/unveiling-our-innovative-new-tv-experience):顶部菜单取代左侧导航、突出 featured 区与上下文信息。
- [Android TV navigation drawer](https://developer.android.com/design/ui/tv/guides/components/navigation-drawer):分类导航与 TV 焦点层级;本项目取其「菜单—内容」两层焦点模型,实现为顶部栏。
- [Android TV app quality](https://developer.android.google.cn/distribute/essentials/quality/tv):D-pad 可达性与明确的焦点反馈。

## 联网查阅的来源

- [Emby Items API](https://dev.emby.media/reference/RestAPI/ItemsService/getItems.html)：观看状态、收藏、继续观看、年份、流派和排序参数。`Genres` 多值使用竖线，`Years` 和 `Filters` 使用逗号。
- [Emby Genres API](https://dev.emby.media/reference/RestAPI/GenresService/getGenres.html)：按父片库查询完整流派列表，使用 `StartIndex`／`Limit` 分页，避免用首屏数据冒充所有选项。
- [Android TV navigation drawer](https://developer.android.com/design/ui/tv/guides/components/navigation-drawer)：清晰的分类导航与 TV 焦点层级。
- [WCAG 2.2 Target Size](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html)：保证触控目标及间距。手机主要操作按不小于 48dp 设计。
- [NN/g Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)：按类别逐步展示选项，避免将所有年份、流派和操作挤进一个长弹窗。

截图脚本另外参考的 Flutter／Playwright 官方实践见 [README](README.md)。原型截图、像素回归、HTTP／控制器测试和目标手机的真实播放证据分别报告，不把夹具速度当作真实设备测量。
