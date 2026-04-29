# iOS UI 组件目录

> 这份文档维护一份**可复用的 SwiftUI 组件清单**，避免在新功能里重复造轮子。
> 写新页面之前请先扫一遍这里；新增可复用组件时也请把它登记进来。

源文件统一放在 `ios-app/IbiliApp/Sources/DesignSystem/`，分两层：

- `DesignSystem/Theme.swift` — 颜色 / token
- `DesignSystem/SharedViews.swift` — `RemoteImage`、`QRCodeImage`、`GlassSurface` 等基础视图
- `DesignSystem/BiliFormat.swift` — 数字 / 时长 / 日期格式化函数
- `DesignSystem/Components/` — 复合组件：pill、section header、video cover、flow layout 等

业务侧（如 `Features/Home/VideoCardView.swift`、`Features/Search/SearchResultCardView.swift`）应**只组合**这些底层组件，不要再各自重写。

---

## 主题 Token (`IbiliTheme`)

| Token | 用途 |
|---|---|
| `IbiliTheme.accent` | 品牌强调色（粉色），用于按钮、图标、被选中态 |
| `IbiliTheme.background` | 页面底色 |
| `IbiliTheme.surface` | 卡片 / pill 表面色 |
| `IbiliTheme.textPrimary` | 主文本 |
| `IbiliTheme.textSecondary` | 副文本 / 提示文本 |

**Do**：所有自定义 `.foregroundStyle` / `.background` 都通过 token 取色。
**Don't**：写死 `Color.pink` / `Color(.systemGray5)` 等 magic value。

---

## 基础视图 (`SharedViews.swift`)

### `RemoteImage`

带磁盘缓存、失败重试、可指定目标像素尺寸的远程图片视图。**所有**封面、头像加载都应通过它。

```swift
RemoteImage(
    url: item.cover,
    contentMode: .fill,
    targetPointSize: CGSize(width: cardW, height: coverH),
    quality: settings.resolvedImageQuality()
)
```

### `QRCodeImage`

把任意字符串渲染为二维码 `Image`，登录页用。

### `GlassSurface`

毛玻璃容器，播放器面板等场景使用。

---

## 格式化函数 (`BiliFormat`)

| 函数 | 输入 → 输出 |
|---|---|
| `BiliFormat.compactCount(_:)` | `15234 → "1.5万"` / `123456789 → "1.2亿"` |
| `BiliFormat.duration(_:)` | `754 → "12:34"` / `3723 → "1:02:03"` |
| `BiliFormat.relativeDate(_:)` | `now-30s → "刚刚"` / `7天外 → "MM-dd"` / `跨年 → "yyyy-MM-dd"` |

**Do**：写新卡片 / 列表项时直接调用。
**Don't**：在视图里新写一个 `formatCount` —— 已经踩过坑（首页/搜索两份逻辑漂移）。

---

## 复合组件 (`DesignSystem/Components/`)

### `IbiliPill`

胶囊 pill。三种风格：

| Style | 视觉 | 场景 |
|---|---|---|
| `.neutral` | 灰底主文 | 未选中筛选项 / 历史 chip |
| `.selected` | 灰底粉文 | 选中的筛选项（搜索结果上方 `视频`） |
| `.accent` | 粉底白文 | 主要 CTA |

```swift
IbiliPill(title: "鬼畜", systemImage: "waveform", style: .selected)
IbiliPill(title: "时长", trailingSystemImage: "chevron.down")
```

### `IbiliSectionHeader`

带 SF Symbol 的小标题，可选 trailing 槽位放“清空 / 更多”按钮。

```swift
IbiliSectionHeader(title: "搜索历史", systemImage: "clock") {
    Button("清空") { history.clear() }
}
IbiliSectionHeader(title: "分区", systemImage: "square.grid.2x2.fill")  // 无 trailing
```

### `OverlayChip`

视频封面上的深色半透明胶囊（播放数 / 弹幕数 / 时长）。

```swift
OverlayChip(systemImage: "play.fill", text: BiliFormat.compactCount(item.play))
OverlayChip(text: BiliFormat.duration(item.durationSec), isMonospaced: true)
```

### `VideoCoverView`

视频封面 + 播放数 / 时长 overlay 的标准容器。**首页 `VideoCardView` 和搜索 `SearchResultCardView` 共用此组件**。

```swift
VideoCoverView(
    cover: item.cover,
    width: cardW,
    imageQuality: settings.resolvedImageQuality(),
    playCount: item.play,
    durationSec: item.durationSec,
    durationPlacement: .bottomTrailing  // 或 .topTrailing（窄卡）
)
```

`durationPlacement`：
- `.bottomTrailing` — 时长 chip 紧跟播放数 chip 同一行
- `.topTrailing` — 时长 chip 移到右上角，避免窄卡片底部拥挤

### `FlowLayout`

简易自适应换行布局（Layout 协议实现）。用于历史标签云之类的场景。

```swift
FlowLayout(spacing: 8, lineSpacing: 8) {
    ForEach(history.entries, id: \.self) { entry in
        IbiliPill(title: entry)
    }
}
```

---

## 业务卡片

### `VideoCardView`（首页）

输入 `FeedItemDTO`，输出推荐流卡片。内部组合 `VideoCoverView` + 标题/作者。

### `SearchResultCardView`（搜索结果）

输入 `SearchVideoItemDTO`，多一行 `MM-dd · ❤ X.X万`。也用 `VideoCoverView`。

> 两个卡片**故意没有共用同一个 `View`**：底部信息列差异较大（首页只显示作者；搜索还要日期+点赞），强行合并会引入开关参数膨胀。但**封面层一定共用**。

---

## 编辑指南

写新页面前的 checklist：

1. 颜色用 `IbiliTheme.*`，不要写死。
2. 数字 / 时长 / 日期一律走 `BiliFormat`。
3. 远程图片只用 `RemoteImage`。
4. 任何"标签胶囊"风格 UI 优先用 `IbiliPill` + 三种 style。
5. 任何"封面 + overlay"卡片优先用 `VideoCoverView`。
6. 新增的可复用 UI 落到 `DesignSystem/Components/` 并在本文件登记。
7. 仅本页面用一次的小视图就放在 `Features/<feature>/` 目录里，不要硬塞进 DesignSystem。
