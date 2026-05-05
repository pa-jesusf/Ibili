# iOS UI 组件目录

这份文档维护当前 `DesignSystem/` 的真实清单，避免新页面重复造轮子。

状态说明：本文档以当前仓库实现为准，更新时间为 2026-05。凡是新增通用组件，都应同时更新这里。

## 1. 当前目录结构

当前共享 UI 代码位于 `ios-app/IbiliApp/Sources/DesignSystem/`：

```text
DesignSystem/
  Theme.swift
  SharedViews.swift
  BiliFormat.swift
  EmptyStateView.swift
  ImageDiskCache.swift
  ProMotionScrollHelper.swift
  SelectableTextPresenter.swift
  Components/
    CardInfoSection.swift
    CompactComposerCard.swift
    CompactVideoRow.swift
    ExpandableText.swift
    FlowLayout.swift
    IbiliPill.swift
    IbiliSectionHeader.swift
    IbiliSegmentedTabs.swift
    IconButton.swift
    LabeledMenuButton.swift
    NativeIsolatedPicker.swift
    OverlayChip.swift
    PrivatePhotoPicker.swift
    StatPair.swift
    VideoCoverView.swift
```

业务层应优先组合这些共享组件，而不是在 `Features/*` 里复制样式和交互。

## 2. 主题 Token (`Theme.swift`)

当前主题入口是 `IbiliTheme`。

| Token | 用途 |
| --- | --- |
| `IbiliTheme.accent` | 品牌强调色 |
| `IbiliTheme.background` | 页面背景 |
| `IbiliTheme.surface` | 卡片 / 面板表面 |
| `IbiliTheme.textPrimary` | 主文本 |
| `IbiliTheme.textSecondary` | 次级文本 |

`Theme.swift` 还定义了当前通用毛玻璃容器 `GlassSurface`。当前实现是轻量级集中封装，不是完整的 provider 抽象层。

## 3. 基础共享视图 (`SharedViews.swift`)

### `ImageCache`

进程级内存图片缓存。

### `CoverImagePrefetcher`

列表封面预取器，会和 `RemoteImage` 共享缓存，避免列表滚动时重复下载。

### `RemoteImage`

带内存缓存、磁盘缓存、失败重试、降采样的远程图片视图。封面和头像都应优先通过它加载。

### `QRCodeImage`

把任意字符串渲染为二维码 `Image`。

## 4. 通用工具文件

### `BiliFormat.swift`

统一的数字、时长、日期格式化入口。

### `EmptyStateView.swift`

`emptyState(...)` 帮助函数，作为 iOS 16 下 `ContentUnavailableView` 的替代。

### `ImageDiskCache.swift`

磁盘 LRU 图片缓存，支撑 `RemoteImage` 冷启动复用和设置页缓存清理。

### `ProMotionScrollHelper.swift`

`ProMotionScrollHint` 修饰器，在用户主动滚动期间请求更高刷新率。

### `SelectableTextPresenter.swift`

把长文本放进可选择、可滚动的 UIKit sheet 中，供标题、简介、评论等“选择复制”场景使用。

## 5. 复合组件 (`Components/`)

### `CardInfoSection`

视频卡片底部信息区。首页卡片和搜索结果卡片共用这层元信息布局。

### `CompactComposerCard`

紧凑输入卡片，给弹幕发送、评论发送等底部输入面板复用。

### `CompactVideoRow`

横向紧凑视频行，适合相关视频、历史、收藏、稍后再看等纵向列表场景。

### `ExpandableText`

带“展开 / 收起”的多行文本，用于视频简介、UP 主简介等长文本。

### `FlowLayout`

简易自动换行布局，用于标签云、历史词条等场景。

### `IbiliPill`

通用胶囊按钮 / 标签组件，支持 `neutral`、`selected`、`accent` 三种视觉风格。

### `IbiliSectionHeader`

带可选图标和 trailing 区域的 section header。

### `IbiliSegmentedTabs`

项目级分段切换控件。`IbiliSegmentedTabs.swift` 内还包含 `NavigationTrailingSegmentedControl`。

### `IconButton`

以图标为主的圆形按钮，主要服务于播放器 overlay 和详情页操作区。

### `LabeledMenuButton`

“图标 + 短文字”型菜单按钮，适合播放器右上角这类图标本身不够明确的入口。

### `NativeIsolatedPicker`

局部 `UISegmentedControl` 包装，避免污染全局 `appearance()`。

### `OverlayChip`

封面上的半透明信息胶囊，用于播放数、时长等 overlay。

### `PrivatePhotoPicker`

基于 `PHPickerViewController` 的图片选择器包装，不主动请求整库照片权限。

### `StatPair`

“图标 + 数值/标签”的竖向操作项，用于点赞、投币、收藏、稍后再看等操作行。

### `VideoCoverView`

统一的视频封面组件，内建播放数 / 时长 overlay 逻辑。

## 6. 当前复用关系

- 首页 `VideoCardView` 和搜索 `SearchResultCardView` 复用 `VideoCoverView`。
- 首页和搜索卡片的底部信息区复用 `CardInfoSection`。
- 搜索历史、搜索类型、视频标签等场景复用 `IbiliPill`。
- 视频详情与空间页的分段切换复用 `IbiliSegmentedTabs`。
- 播放器顶部和详情页操作区优先用 `IconButton` / `LabeledMenuButton` / `StatPair`。
- 相关视频、历史、收藏、稍后再看等列表优先用 `CompactVideoRow`。

## 7. 使用规则

1. 颜色和前景样式优先走 `IbiliTheme`，不要在业务页面里写死一组新颜色。
2. 数字、时长、相对日期优先走 `BiliFormat`。
3. 远程图片优先走 `RemoteImage`，不要在业务层重新包 `AsyncImage`。
4. 任何“封面 + overlay”优先复用 `VideoCoverView`。
5. 任何“标签胶囊”优先考虑 `IbiliPill`。
6. 任何确定会跨 feature 复用的 UI，都应落到 `DesignSystem/` 并登记到本文档。
7. 仅某个页面内部使用一次的小视图，继续放在对应 `Features/<Feature>/` 下即可。