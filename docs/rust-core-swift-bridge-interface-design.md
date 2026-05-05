# Rust 核心与 Swift 桥接接口设计

## 1. 目的

这份文档描述当前 Rust core 与原生 Swift 应用之间的桥接契约。

截至 2026-05，仓库里还没有独立的 `ProtocolCoreBridge` Swift package。当前 bridge 直接位于 `ios-app/IbiliApp/Sources/Bridge/`，并作为 app target 的一部分编译。

相关文档：

- `./ios-native-development-guide.md`
- `./ios-workspace-architecture.md`
- `./upstream-sync-implementation.md`

## 2. 当前分层

```text
SwiftUI Feature / ViewModel
  -> Swift bridge (`Bridge/CoreClient.swift`)
  -> Rust C ABI (`ibili.h`)
  -> `ibili_ffi`
  -> `ibili_core`
```

规则：

- Feature 不得直接调用 C ABI 导出函数。
- Swift 负责最外层的 JSON 编码和 DTO 解码。
- Rust 负责协议逻辑、签名、路由、传输和响应解析。

## 3. 当前工作区结构

### 3.1 Swift 侧

`ios-app/IbiliApp/Sources/Bridge/` 当前包含：

- `CoreClient.swift`：共享 bridge client 和错误映射
- `CoreDTOs.swift`：供 feature 使用的可编码 / 可解码 DTO
- `SessionStore.swift`：会话快照的本地持久化
- `BiliImageURL.swift`：应用内共用的图片 URL 归一化辅助逻辑

### 3.2 Rust 侧

`core/rust/` 当前包含：

- `crates/ibili_core/`：协议和服务逻辑
- `crates/ibili_ffi/`：C ABI 包装和 JSON method dispatch

当前 `ibili_core` 模块包括：

- `auth`
- `cdn`
- `danmaku`
- `dynamic`
- `feed`
- `http`
- `interaction`
- `packaging`
- `reply`
- `search`
- `session`
- `signer`
- `user_space`
- `video`

## 4. 当前 C ABI

公开头文件位于 `core/rust/crates/ibili_ffi/include/ibili.h`。

当前导出面如下：

```c
typedef struct IbiliCore IbiliCore;

IbiliCore* ibili_core_new(const char* config_json);
void ibili_core_free(IbiliCore* core);
void ibili_string_free(char* s);
char* ibili_call(IbiliCore* core, const char* method, const char* args_json);
```

这套接口比旧的“多函数 ABI”设想要窄得多。当前 bridge 使用一个长生命周期 core handle，加一个 JSON dispatch 入口。

## 5. 请求 / 响应契约

### 5.1 Swift -> Rust

Swift 把 method 参数编码成 JSON 字符串，然后调用：

```text
ibili_call(handle, method, args_json)
```

### 5.2 Rust -> Swift

Rust 始终返回一个新分配的 UTF-8 JSON 字符串，格式如下：

```json
{ "ok": true, "data": ... }
```

或：

```json
{ "ok": false, "error": { "category": "...", "message": "...", "code": 123 } }
```

Swift 必须用 `ibili_string_free` 释放返回的字符串。

## 6. Swift Bridge 的职责

`CoreClient.swift` 是当前桥接门面。

职责：

- 持有共享 `IbiliCore` handle 的生命周期
- 把请求 DTO 序列化为 JSON
- 调用 `ibili_call`
- 把成功响应解码为 Swift DTO
- 把错误 envelope 映射为 `CoreError`
- 暴露上层可直接调用的方法，例如 `feedHome()`、`playUrl()`、`replyMain()`、`searchVideo()`、`packagingOfflineBuild()`

非职责：

- 不在 SwiftUI view 中决定 endpoint 选择逻辑
- 不在 Swift 侧手写签名
- 不在 DTO 解码之外做协议解析

## 7. 当前服务接口面

当前 Rust dispatch table 是基于 method 字符串，而不是基于多个 client 类型。

### 7.1 Session

- `session.snapshot`
- `session.restore`
- `session.logout`

### 7.2 Auth

- `auth.tv_qr.start`
- `auth.tv_qr.poll`

### 7.3 Feed

- `feed.home`
- `feed.popular`

### 7.4 Video 与播放

- `video.playurl`
- `video.playurl.tv`
- `video.view_cid`
- `video.view_full`
- `video.related`
- `danmaku.list`

### 7.5 Search

- `search.video`

### 7.6 评论与交互

- `reply.main`
- `reply.detail`
- `interaction.like`
- `interaction.dislike`
- `interaction.coin`
- `interaction.triple`
- `interaction.favorite`
- `interaction.relation`
- `interaction.watchlater_add`
- `interaction.watchlater_del`
- `interaction.archive_relation`
- `interaction.fav_folders`
- `interaction.heartbeat`
- `interaction.watchlater_aids`
- `interaction.reply_like`
- `interaction.send_danmaku`
- `interaction.reply_add`
- `interaction.upload_bfs`
- `interaction.emote_panel`

### 7.7 用户与动态

- `user.card`
- `user.history`
- `user.fav_resources`
- `user.bangumi_follow`
- `user.watchlater_list`
- `user.followings`
- `user.followers`
- `user.space_arc_search`
- `dynamic.feed`
- `dynamic.space_feed`
- `dynamic.like`

### 7.8 Packaging

- `packaging.offline_build`

这个方法会从导出的 diagnostics 样本生成本地 packaging workspace，目前已经打通 Rust、FFI 和 `CoreClient`。

## 8. 错误模型

当前 Swift 侧错误类型为：

```text
CoreError {
  category: String
  message: String
  code: Int64?
}
```

当前行为：

- 登录过期会通过 `CoreError.isLoginExpired` 归一化判断
- `AppSession` 会监听登录过期通知，并清理持久化会话状态

## 9. 内存归属规则

- Swift 通过 `ibili_core_new` 创建一个 core handle
- Swift 通过 `ibili_core_free` 销毁它
- 每个 `ibili_call` 返回的字符串都必须通过 `ibili_string_free` 释放
- 借用指针不能越过单次 FFI 调用边界

这些规则已经由 `CoreClient` 实现。

## 10. 并发模型

C ABI 当前是同步接口。

当前实践规则：

- bridge 通过 `NSLock` 串行化单次 FFI 调用
- 较重的 bridge 调用应由调用方放在 async Swift task 或后台工作里执行
- Rust 内部仍然可以自由组织实现，而不必把 async 机制暴露到 ABI 边界之外

## 11. 构建与打包

当前构建流程：

1. 把 `ibili_ffi` 编译为 `staticlib`
2. 打包 `IbiliCore.xcframework`
3. 把 XCFramework 链接进 iOS app target

当前关键文件：

- `core/rust/Cargo.toml`
- `core/rust/crates/ibili_ffi/Cargo.toml`
- `core/rust/crates/ibili_ffi/include/ibili.h`
- `ios-app/Frameworks/IbiliCore.xcframework`
- `tools/build_rust_xcframework.sh`

## 12. 后续演进

未来仍然可以把 bridge 提取成单独的 Swift package。

如果真的这么做，当前契约仍然应当保持不变：

- Swift 负责 DTO 映射
- Rust 负责协议逻辑
- app 仍然通过一套窄 C ABI 通信，而不是为每个 feature 暴露大量导出函数