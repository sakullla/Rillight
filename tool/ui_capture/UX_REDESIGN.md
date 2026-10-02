# 三端 UI/UX 重设计依据

参考用户提供的 `docs/test/` 手机详情、首页、片库和桌面筛选截图；这些本地图片不随代码打包。

## 信息与交互

- 手机采用独立的阅读字号、触控行高和默认贴底导航；保留用户已经选择的悬浮导航偏好。窄手机使用两列海报，较宽手机使用三列；标题可占两行，评分与季数分开呈现。
- Emby `Series.ChildCount` 是直接子项数量，应显示季数，不能当作全集数。分集继续显示季集编号。
- 加载页与成品共用 `PhoneDetailCaption`，保持头图、标题、元数据和主操作的布局一致；首页与片库骨架保留实际图片和文字区域的尺寸。
- 筛选采用分类导航、可搜索选项、已选摘要及固定的重置／应用区。选择先保存在草稿，取消不发查询；年份和流派支持多选。纯电影／剧集库不展示无效的混合类型切换。
- 手机以紧凑分类条进入选项，桌面和 TV 使用左右分栏；TV 仍保留可见焦点和独立遥控器操作。年份不再局限于首批海报出现的年份，流派通过 Emby `/Genres` 分页获取，失败可重试。
- 缓存范围只绘制已验证的媒体时间或独立的字节覆盖；手机 Slider 的主题顺序不再覆盖缓存轨道。网速采样不等待媒体索引计算，归零时仍保留已缓存区间。

## 联网查阅的来源

- [Emby Items API](https://dev.emby.media/reference/RestAPI/ItemsService/getItems.html)：观看状态、收藏、继续观看、年份、流派和排序参数。`Genres` 多值使用竖线，`Years` 和 `Filters` 使用逗号。
- [Emby Genres API](https://dev.emby.media/reference/RestAPI/GenresService/getGenres.html)：按父片库查询完整流派列表，使用 `StartIndex`／`Limit` 分页，避免用首屏数据冒充所有选项。
- [Android TV navigation drawer](https://developer.android.com/design/ui/tv/guides/components/navigation-drawer)：清晰的分类导航与 TV 焦点层级。
- [WCAG 2.2 Target Size](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html)：保证触控目标及间距。手机主要操作按不小于 48dp 设计。
- [NN/g Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)：按类别逐步展示选项，避免将所有年份、流派和操作挤进一个长弹窗。

截图脚本另外参考的 Flutter／Playwright 官方实践见 [README](README.md)。原型截图、像素回归、HTTP／控制器测试和目标手机的真实播放证据分别报告，不把夹具速度当作真实设备测量。
