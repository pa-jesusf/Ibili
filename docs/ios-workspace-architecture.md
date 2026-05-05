# iOS 工作区架构

## 1. 目的

这份文档描述当前工作区和 iOS 工程布局。

截至 2026-05，仓库已经不再符合早期“拆成多个本地 Swift package”的设想。这里的说明以磁盘上的真实结构为准。

相关文档：

- `./ios-native-development-guide.md`
- `./rust-core-swift-bridge-interface-design.md`
- `./ios-ui-components.md`
- `./upstream-sync-implementation.md`

## 2. 顶层工作区结构

```text
Ibili/
  docs/
  core/
    rust/
  ios-app/
  tools/
  upstream-piliplus/
  ibili-diagnostics/
```

### 2.1 目录职责

- `docs/`：架构、设计、调试和维护文档
- `core/rust/`：Rust workspace，包含 `ibili_core` 和 `ibili_ffi`
- `ios-app/`：原生 iOS 应用、XcodeGen 配置、XCFramework 挂载点
- `tools/`：当前构建流程使用的脚本
- `upstream-piliplus/`：上游 Flutter 参考实现
- `ibili-diagnostics/`：导出的播放诊断和 packaging workspace 样本

## 3. iOS 工程布局

iOS 工程由 `ios-app/project.yml` 生成。

当前 targets：

1. `Ibili` 应用 target
2. `IbiliTests` 单元测试 target

`project.yml` 当前的重要属性：

- 部署版本：iOS 16.0
- 生成出的项目名：`Ibili`
- Rust framework 依赖：`Frameworks/IbiliCore.xcframework`
- unsigned 构建流程下默认关闭 code signing

## 4. 源码目录结构

`ios-app/IbiliApp/Sources/` 当前真实布局如下：

```text
App/
Bridge/
DesignSystem/
Features/
```

### 4.1 `App/`

负责应用启动和全局状态。

当前文件包括：

- `IbiliApp.swift`
- `RootView.swift`
- `DeepLinkRouter.swift`
- `AppSession.swift`
- `AppSettings.swift`
- `Logging/`

### 4.2 `Bridge/`

负责 Swift 侧的 Rust 桥接。

当前文件包括：

- `CoreClient.swift`
- `CoreDTOs.swift`
- `SessionStore.swift`
- `BiliImageURL.swift`

这个目录就是当前仓库里旧 `ProtocolCoreBridge` 设想的实际落点。

### 4.3 `DesignSystem/`

负责共享视觉 token、基础视图和复合组件。

关键文件：

- `Theme.swift`
- `SharedViews.swift`
- `BiliFormat.swift`
- `EmptyStateView.swift`
- `ImageDiskCache.swift`
- `Components/`

### 4.4 `Features/`

负责产品功能页。

当前 feature 目录包括：

- `Auth/`
- `Dynamic/`
- `Home/`
- `Logs/`
- `Player/`
- `Profile/`
- `Search/`
- `Settings/`
- `UserSpace/`
- `VideoDetail/`

## 5. 依赖规则

iOS 应用目前仍是单一 target，因此这些边界主要靠目录约定而不是编译期 package 约束。

要求的依赖方向：

```text
Features -> App / Bridge / DesignSystem
Bridge -> Rust C ABI
Rust C ABI -> Rust service modules
```

规则：

- Feature 不得直接调用原始 FFI 函数。
- DesignSystem 不得 import feature 模块。
- Rust 特有的传输、签名细节不得从 `Bridge/` 泄漏到外层。
- `App/` 可以协调导航和共享状态，但协议逻辑仍归 Rust 所有。

## 6. 构建产物与工具

当前构建脚本：

- `tools/build_rust_xcframework.sh`
- `tools/build_unsigned_ipa.sh`

当前构建流程：

1. 为 iOS targets 构建 Rust workspace
2. 打包 `IbiliCore.xcframework`
3. 用 XcodeGen 生成 Xcode 工程
4. 在关闭签名的条件下 archive app
5. 把 `Ibili.app` 重新打包为 unsigned IPA

关键生成产物：

- `ios-app/Frameworks/IbiliCore.xcframework`
- `ios-app/Ibili.xcodeproj`
- `dist/Ibili-unsigned.ipa`

## 7. 诊断与测试

- 播放器和 packaging 诊断输出位于 `ibili-diagnostics/`
- Swift 测试位于 `ios-app/IbiliApp/Tests/`
- Rust 测试位于 `core/rust/`

## 8. 后续模块化可能性

未来仍然可以把 `Bridge/`、`DesignSystem/` 或部分 `Features/` 提取成 Swift package。

但那属于未来重构，不是当前架构。在真正完成这类重构之前，文档应当始终引用真实源码目录，而不是旧的 package 方案。