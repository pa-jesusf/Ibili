# 文档总览

这个目录里的文档分成三类：

1. 当前实现说明
2. 设计 / 路线图文档
3. 历史排障记录

在依赖或修改任意文档之前，先看这份索引。

## 当前实现说明

- `ios-native-development-guide.md`
  - 作用：说明当前原生 iOS 客户端的高层架构规则。
  - 适用场景：需要了解当前架构边界、UI 约束和运行时规则时。
- `ios-workspace-architecture.md`
  - 作用：说明当前工作区布局、target 结构、源码目录和构建产物。
  - 适用场景：需要快速定位代码或判断改动应该放在哪里时。
- `rust-core-swift-bridge-interface-design.md`
  - 作用：说明当前 Rust 和 Swift 之间的桥接契约与服务接口。
  - 适用场景：修改 `core/rust`、`ibili_ffi` 或 `ios-app/IbiliApp/Sources/Bridge` 时。
- `ios-ui-components.md`
  - 作用：说明当前 DesignSystem 组件清单和复用规则。
  - 适用场景：新增或重构 SwiftUI 界面时。

## 设计 / 路线图文档

- `ios-avplayer-packaging-implementation-design.md`
  - 作用：说明 AVPlayer 长期打包方案的方向。
  - 当前状态：M1 离线打包已经落地，live packaging 架构仍然属于路线图。
- `upstream-sync-implementation.md`
  - 作用：说明上游漂移检测和协议回归流程的规划。
  - 当前状态：这是设计目标；仓库里还没有 `tools/upstream-sync/` 自动化实现。

## 历史记录

- `ios-remux-fallback-debug-notes.md`
  - 作用：归档 qn125 / remux 问题线的排障结论。
  - 当前状态：历史记录，不代表当前运行时设计。

## 维护规则

- 如果文档描述的是当前代码，实现改动时要同步更新文档。
- 如果文档是有意保持前瞻性的设计文档，文件开头要明确标出来。
- 如果文档是历史记录，要保留“历史”标识，不要和当前架构说明混在一起。
- 不要在这个目录里引用不存在的文档；要么删掉引用，要么在同一个改动里补上目标文档。