# iOS 原生开发指南

## 1. 目的

这份文档记录当前原生 iOS 客户端的架构规则。

截至 2026-05，本仓库已经明确采用下面这套实现形态：

- Rust 协议核心位于 `core/rust/`
- 原生 SwiftUI 应用位于 `ios-app/`
- 上游 Flutter 工程位于 `upstream-piliplus/`，只作为协议行为参考，不作为运行时依赖

这份指南只描述当前方向和实际约束，不再保留旧的 Swift Package 包图设想。以仓库当前已经落地的代码为准。

配套文档：

- `./ios-workspace-architecture.md`
- `./rust-core-swift-bridge-interface-design.md`
- `./upstream-sync-implementation.md`
- `./ios-ui-components.md`

## 2. 当前项目形态

当前交付形态是“原生 iOS 应用 + Rust 协议核心”。

- iOS 应用由 `ios-app/project.yml` 驱动，目前生成一个应用 target 和一个单元测试 target。
- SwiftUI 业务功能位于 `ios-app/IbiliApp/Sources/Features/`。
- Swift 到 Rust 的桥接位于 `ios-app/IbiliApp/Sources/Bridge/`。
- 共享视觉基础设施和可复用控件位于 `ios-app/IbiliApp/Sources/DesignSystem/`。
- Rust core 负责签名、传输、鉴权、首页、视频、弹幕、交互、搜索、动态、空间页和 packaging 等协议能力。

当前仓库里没有独立的 `Application` 或 `Infrastructure` Swift package 图。它们可以作为抽象分层概念存在，但真正的源码边界以当前目录结构为准。

## 3. 核心原则

### 3.1 原生优先

除非测量证明 Apple 原生框架无法满足目标场景，否则 iOS 客户端应优先使用系统能力。

- 页面和导航优先使用 SwiftUI。
- 播放、音频会话、PiP、锁屏媒体控制等优先使用 `AVPlayer` 和系统媒体能力。
- 导航与常规交互优先使用 `NavigationStack`、`TabView`、`sheet`、`searchable`、菜单、上下文菜单和分享面板。
- UIKit 只用于填补 SwiftUI 的明确缺口。

当前一个重要例外是：播放器路由并不是 `fullScreenCover`，而是 `RootView` 内的自定义 overlay host。这样做是为了保留右侧边缘返回时对底层页面的自然揭示效果。

### 3.2 协议逻辑与 UI 分离

UI 层不能知道 WBI、AppSign、gRPC metadata、原始 endpoint 字符串或 FFI 细节。

- Feature 和 view model 通过 Swift bridge 调用能力。
- 只有 bridge 层能直接调用 C ABI。
- Rust 负责请求拼装、签名、路由和响应解析。
- DesignSystem 只能包含表现层逻辑，不能掺杂业务逻辑。

### 3.3 上游兼容性是产品要求

`upstream-piliplus/` 是这个仓库的协议行为参考。

- 本项目不机械照搬 Flutter 上游结构。
- Rust core 要尽量维持与上游在鉴权、首页、playurl、弹幕和交互流程上的兼容。
- 即使自动同步工具还没落地，协议漂移检测本身仍然是架构要求。

### 3.4 诊断能力属于架构一部分

播放和协议失败必须留下足够证据，便于后续定位。

- 播放器 live HLS 代理路径会导出诊断信息。
- 离线 packaging workspace 由诊断样本生成。
- 构建校验应走真实 XCFramework + Xcode 构建链路，而不是只靠局部代码片段。

## 4. 当前分层

当前生产路径如下：

```text
SwiftUI View / ViewModel
  -> App / Feature 状态对象
  -> Bridge/CoreClient.swift
  -> C ABI (`ibili_core_new`, `ibili_call`, `ibili_string_free`, `ibili_core_free`)
  -> Rust core services
```

这条链路比旧的 package 化设想更扁平，但边界仍然重要，只是现在通过目录约定而不是 Swift package import 关系来维持。

## 5. UI 策略

### 5.1 App Shell

主壳目前位于 `App/RootView.swift`。

- 未登录用户进入原生登录流程。
- 已登录用户进入包含 Home、Dynamic、Search、Profile 的 `TabView`。
- 播放器堆栈通过 `DeepLinkPlayerHost` 挂在 tab 壳之上。

### 5.2 默认使用 SwiftUI

优先使用的构件：

- `NavigationStack`
- `TabView`
- `ScrollView` 与 lazy 容器
- `sheet`
- `searchable`
- 只在必要时引入小范围 UIKit 包装

### 5.3 设计系统

`DesignSystem/` 是当前共享视觉层。

- `Theme.swift` 定义颜色和当前 `GlassSurface` 包装。
- `SharedViews.swift` 提供 `RemoteImage`、`QRCodeImage`、图片缓存辅助逻辑等基础能力。
- `Components/` 提供 pill、segmented tabs、icon button、封面样式、紧凑列表行等可复用组件。

当前 glass 实现是轻量集中封装：`GlassSurface` 统一了回退材质的处理，但仓库里还没有完整的 iOS 26 glass provider 抽象层。

## 6. 播放策略

iOS 播放能力保持原生实现。

- `AVPlayer` 是播放内核。
- 默认运行时引擎是 `HLSProxyEngine`，通过 `LocalHLSProxy` 把 DASH/fMP4 元数据转换成 localhost HLS 入口。
- 长期 packaging 路线见 `ios-avplayer-packaging-implementation-design.md`。
- 历史 remux 实验已经归档在 `ios-remux-fallback-debug-notes.md`，不属于当前运行时路径。

## 7. 不可妥协的规则

- SwiftUI feature 不得直接调用原始 FFI 符号。
- Feature 不得手写签名参数或 endpoint 字符串。
- DesignSystem 文件不得 import feature 业务逻辑。
- 播放器修复不能重新把 FFmpeg 实时 remux 作为主运行时路径。
- 构建或播放验证必须走真实 app 链路，不能只靠局部代码片段。

## 8. 相关文档

- `./ios-workspace-architecture.md`
- `./rust-core-swift-bridge-interface-design.md`
- `./ios-ui-components.md`
- `./ios-avplayer-packaging-implementation-design.md`
- `./ios-remux-fallback-debug-notes.md`