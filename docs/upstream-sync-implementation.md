# 上游同步与协议回归实现方案

## 状态说明

这份文档描述的是设计目标，不是当前仓库里已经完整落地的工具实现。

截至 2026-05：

- `upstream-piliplus/` 已存在，并作为协议行为参考
- Rust core 已经在 `core/rust/` 中直接镜像了不少上游行为
- 仓库中还没有真正落地的 `tools/upstream-sync/` 自动化实现

因此，下面的内容应理解为“计划中的自动化方案”，而不是“仓库当前已经具备的能力”。

## 1. 目的

这份文档说明如何跟踪 upstream PiliPlus 仓库中与协议相关的变化，并把这些变化转化为可执行的维护动作。

目标不是机械地镜像上游源码。

目标是：

- 尽早发现协议行为变化
- 把上游行为归一化为 manifests
- 给变化分类并评估风险
- 对本地 core library 运行回归检查
- 在发现漂移时生成明确的维护任务

建议与以下文档配套阅读：

- `./ios-native-development-guide.md`
- `./ios-workspace-architecture.md`
- `./rust-core-swift-bridge-interface-design.md`

## 2. 事实来源

当前工作区中的上游协议参考位于：

- `upstream-piliplus/`

本地需要维护的实现位于：

- `core/`
- `ios-app/`

同步系统应把上游视为“行为参考”，而不是直接的代码依赖。

## 3. 需要观察的变更范围

同步系统应优先跟踪这些上游文件和区域：

- `upstream-piliplus/lib/http/api.dart`
- `upstream-piliplus/lib/http/login.dart`
- `upstream-piliplus/lib/http/video.dart`
- `upstream-piliplus/lib/http/init.dart`
- `upstream-piliplus/lib/utils/accounts/account_manager/account_mgr.dart`
- `upstream-piliplus/lib/utils/accounts/account.dart`
- `upstream-piliplus/lib/utils/accounts/api_type.dart`
- `upstream-piliplus/lib/utils/app_sign.dart`
- `upstream-piliplus/lib/utils/wbi_sign.dart`
- `upstream-piliplus/lib/utils/accounts/grpc_headers.dart`
- `upstream-piliplus/lib/grpc/url.dart`
- `upstream-piliplus/lib/grpc/**/*.pb*.dart`
- `upstream-piliplus/lib/common/constants.dart`

这些文件定义了最容易导致本地 core library 失效的行为。

## 4. 系统组件

建议的同步系统组件如下：

1. `UpstreamFetcher`
2. `ReferenceExtractor`
3. `ManifestStore`
4. `DiffClassifier`
5. `RegressionRunner`
6. `ReportGenerator`
7. `TaskEmitter`

## 5. 组件职责

### 5.1 `UpstreamFetcher`

职责：

- 拉取最新上游 commit
- 记录最新 tag 和 release 元数据
- 保存 commit SHA 历史，供本地对比使用
- 在需要时维护一个浅克隆副本

建议输出：

- `latest_sha`
- `latest_tag`
- `latest_release`
- `changed_files`

建议触发频率：

- 开发分支每 6 小时一次
- 资源不足时至少每天一次
- 发布前允许手动触发

### 5.2 `ReferenceExtractor`

职责：

- 解析被观察的上游文件
- 提取 endpoint、鉴权和签名行为，归一化为 manifests
- 避免把原始上游源码当成主要产物保存

建议的提取策略：

- 第一阶段：对已知模式使用正则和轻量结构化解析辅助函数
- 第二阶段：当提取面扩大后，升级到更正式的解析器

提取过程应当是确定性的、幂等的。

### 5.3 `ManifestStore`

职责：

- 保存当前 manifests
- 保存上一版 manifests
- 保存产生这些 manifests 的上游 SHA 元数据
- 让 diff 结果可以稳定复现

建议存储位置：

```text
tools/upstream-sync/artifacts/
  manifests/
  diffs/
  reports/
```

### 5.4 `DiffClassifier`

职责：

- 比较新旧 manifests
- 给变化打上风险类别标签
- 决定应该运行哪些回归套件
- 判断是否需要人工 review 任务

### 5.5 `RegressionRunner`

职责：

- 对本地 core library 运行协议关键路径检查
- 记录通过或失败结果
- 把结果附加到变更报告中

### 5.6 `ReportGenerator`

职责：

- 总结上游变化
- 解释哪一块协议表面发生了变化
- 列出受影响的本地模块
- 附上回归结果

### 5.7 `TaskEmitter`

职责：

- 在需要时创建 PR、issue 或内部任务
- 按风险类型打标签
- 附上直接证据和建议归属模块

## 6. Manifest 设计

建议维护这些 manifests：

1. `endpoint_manifest.json`
2. `auth_policy_manifest.json`
3. `signing_manifest.json`
4. `grpc_manifest.json`
5. `proto_fingerprint_manifest.json`
6. `login_flow_manifest.json`
7. `playurl_manifest.json`

### 6.1 Endpoint Manifest

用途：

- 跟踪 endpoint 名称、域名和路由分类

建议字段：

```json
{
  "name": "tvPlayUrl",
  "path": "/x/tv/playurl",
  "base_domain": "app.bilibili.com",
  "family": "playurl",
  "transport": "rest",
  "source_file": "lib/http/api.dart"
}
```

### 6.2 Auth Policy Manifest

用途：

- 跟踪不同路由族使用什么鉴权策略

建议字段：

```json
{
  "route": "tvPlayUrl",
  "policy": "app_signed",
  "needs_access_key": true,
  "needs_cookie": false,
  "needs_csrf": false,
  "needs_wbi": false,
  "needs_grpc_headers": false
}
```

### 6.3 Signing Manifest

用途：

- 跟踪 AppSign 和 WBI 的输入行为

建议字段：

```json
{
  "app_sign": {
    "appkey": "dfca71928277209b",
    "inputs": ["appkey", "ts", "sorted_query", "appsec_md5"],
    "source": "lib/utils/app_sign.dart"
  },
  "wbi": {
    "bootstrap": "userInfo.wbi_img",
    "adds": ["wts", "w_rid"],
    "source": "lib/utils/wbi_sign.dart"
  }
}
```

### 6.4 gRPC Manifest

用途：

- 跟踪 gRPC 路由及二进制 metadata 结构

建议字段：

```json
{
  "route": "/bilibili.app.viewunite.v1.View/View",
  "authorization_mode": "identify_v1 access_key",
  "metadata_bins": [
    "x-bili-device-bin",
    "x-bili-network-bin",
    "x-bili-locale-bin",
    "x-bili-fawkes-req-bin",
    "x-bili-metadata-bin"
  ]
}
```

### 6.5 Proto Fingerprint Manifest

用途：

- 检测 protobuf 表面变化，而不把生成后的源码 diff 当作主要信号

建议字段：

- service name
- route name
- message name
- field count
- field numbers
- field names
- field wire types

### 6.6 Login Flow Manifest

用途：

- 跟踪鉴权和风控流程中的分叉点

建议条目：

- TV QR 授权码请求
- TV QR 轮询
- 密码登录
- 短信登录
- 安全中心预校验
- 安全中心短信发送
- 安全中心短信校验
- OAuth code 兑换 access token

### 6.7 Playurl Manifest

用途：

- 检测播放流获取行为的变化

建议字段：

- route family
- required params
- optional params
- `fourk`、`fnval`、`try_look` 等标志位
- 路由是否基于 WBI 或 AppSign

## 7. 变化分类

`DiffClassifier` 应输出下列一个或多个标签：

- `endpoint_added`
- `endpoint_removed`
- `auth_policy_changed`
- `wbi_bootstrap_changed`
- `wbi_param_behavior_changed`
- `app_sign_behavior_changed`
- `grpc_metadata_changed`
- `grpc_route_changed`
- `proto_schema_changed`
- `login_flow_changed`
- `risk_control_flow_changed`
- `playurl_behavior_changed`
- `constants_changed`

建议风险等级：

1. `low`
2. `medium`
3. `high`
4. `critical`

示例：

- `endpoint_added` 通常是 `low` 或 `medium`
- `proto_schema_changed` 通常是 `high`
- `app_sign_behavior_changed` 应视为 `critical`
- `risk_control_flow_changed` 通常是 `high` 或 `critical`

## 8. 回归套件设计

回归套件应验证本地 protocol core，而不是去验证上游 Dart app。

最低建议套件如下：

### 8.1 Feed 回归套件

检查项：

- 通过 WBI 路径拉取首页推荐
- 如果本地支持，也验证使用 app headers 的推荐流路径

### 8.2 Video 回归套件

检查项：

- 视频详情请求
- web playurl 请求
- TV / app playurl 请求
- 流元数据解析

### 8.3 gRPC 回归套件

检查项：

- view 请求
- 弹幕分段请求
- 如果本地支持，也包括 reply 或 dynamic 的 gRPC 路径

### 8.4 Auth 回归套件

检查项：

- 密码登录请求构造
- 短信登录请求构造
- 安全中心请求构造
- TV QR 登录流程请求构造
- OAuth access token 兑换请求构造

### 8.5 Manifest 一致性回归套件

检查项：

- 每个被观察到的上游变化都能映射到 manifest diff
- 每个 manifest diff 都能映射到 classifier label
- 所需的回归套件确实被选中了

## 9. 执行流程

建议执行流程：

1. 拉取最新上游 commit
2. 检测被观察文件是否发生变化
3. 从新的上游快照提取 manifests
4. 与上一版快照进行对比
5. 对 diff 分类
6. 选出必须运行的回归套件
7. 对本地 core library 运行回归检查
8. 生成人类可读报告
9. 如果变化风险达到 `medium` 及以上，则创建任务或 PR

如果被观察文件没有变化，可以跳过耗时阶段。

## 10. 报告格式

每份生成的报告都应包含：

- 上游 commit SHA
- 如果存在则附上上游 tag
- 被观察文件的变更列表
- manifest diff 摘要
- classifier labels
- 风险等级
- 实际运行的回归套件
- 回归结果
- 受影响的本地模块
- 建议归属模块

建议输出文件：

```text
tools/upstream-sync/artifacts/reports/
  2026-04-28T120000Z-main-<sha>.md
```

## 11. 建议的实现布局

建议的工具目录：

```text
tools/upstream-sync/
  README.md
  src/
    fetcher/
    extractor/
    manifests/
    classifier/
    reports/
    tasks/
  artifacts/
    manifests/
    diffs/
    reports/
```

建议的回归目录：

```text
tools/regression/
  README.md
  suites/
    feed/
    video/
    grpc/
    auth/
    manifest/
```

## 12. 归属映射

建议的本地归属映射：

- 鉴权和签名变化 -> `core` 负责人
- gRPC metadata 和 protobuf 变化 -> `core` 负责人
- repository mapping 变化 -> 负责 bridge / 数据映射的负责人
- feature 层连带影响 -> 对应 `Feature*` 负责人
- 因流形态变化导致的播放器连带影响 -> `FeaturePlayer` 负责人

这样可以避免大范围上游变化最后变成无人认领的工作。

## 13. 安全自动化规则

- 不要把协议变化自动 merge 进本地 core。
- 不要在未保存旧版本的情况下覆盖本地 manifests。
- 如果 AppSign、WBI、登录流程或 gRPC metadata 发生变化，就不能把风险错误地判成低风险。
- 遇到 critical 级别上游变化时，没有运行对应回归前不得继续发布。

自动化系统应负责“发现”和“报告”，而不是盲目改代码。

## 14. 第一阶段里程碑

建议顺序：

1. 实现 `UpstreamFetcher`
2. 实现被观察文件过滤器
3. 先做 `endpoint_manifest.json`
4. 再做 `auth_policy_manifest.json`
5. 再做 `signing_manifest.json`
6. 实现 `DiffClassifier`
7. 补齐 feed、video、auth 回归套件
8. 再加入 gRPC 和 proto fingerprint manifests
9. 最后补上报告生成和任务发射

这条顺序能让系统在 extractor 全部完工前，就先提供最有价值的早期预警能力。

## 15. 成功标准

当满足以下条件时，就说明同步系统工作正常：

- 在一个同步周期内就能发现上游协议变化
- 提取出的 manifests 能清楚解释行为差异
- 受影响的表面会自动触发对应回归套件
- 报告能准确指出受影响的本地模块
- 不再需要人工逐个检查所有上游 commit 才能保持同步

达到这个状态后，上游漂移就会从“不可预期的 breakage 来源”，变成“可管理的维护流程”。