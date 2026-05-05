# iOS AVPlayer 长期打包方案实现设计

## 1. 目的

这份文档把 qn125 / HEVC Main10 HDR / Dolby Vision 相关问题的长期方案收敛为一份可实现的设计合同。

它不讨论短期止损，不讨论继续修补 `LocalHLSProxy`，也不讨论继续调 FFmpeg 实时 remux 参数。

它只回答一个问题：

```text
如果我们坚持 AVPlayer，长期上应该提供一条什么样的打包链，才能把 B 站 DASH/fMP4 资源转换成 AVPlayer 可稳定消费的 Apple 兼容 HLS/CMAF 播放输入？
```

## 2. 设计结论

长期目标只有一个：

- 为 AVPlayer 提供真正 Apple 兼容的 HLS/CMAF 输出，且 segment 语义由正式打包层控制。

这意味着：

- 不能继续把 upstream `sidx` 引用直接伪装成 HLS `EXT-X-BYTERANGE` segment。
- 不能继续把 `init.mp4` patch 当作主线方案。
- 不能继续把 FFmpeg 实时 remux 当作 qn125 类问题的长期修复路径。
- 必须引入一个明确的打包器，把 upstream track 资源重组为由我们控制的 init、media segment、playlist 和诊断元数据。

## 3. 目标与非目标

### 3.1 目标

1. 保持 AVPlayer 作为播放内核，保留 PiP、AirPlay、锁屏控制和系统媒体能力。
2. 支持 B 站音视频分离的 DASH/fMP4 输入。
3. 输出 Apple-compatible 的 HLS/CMAF 播放工件。
4. segment 边界必须由打包器显式控制，而不是盲信 upstream `sidx`。
5. 对 qn125、HEVC Main10 HDR、Dolby Vision 等高风险变体给出可验证、可失败、可诊断的路径。
6. 对普通可播流保留后续统一迁移空间，但第一阶段允许只覆盖高风险变体。

### 3.2 非目标

1. 不把自动降档视为方案完成。
2. 不把整文件先下载完再播视为长期架构。
3. 不在 `FeaturePlayer` 内做协议判断、box patch 或 segment 重写。
4. 不依赖“再多补一个 box”式的本地代理热修。
5. 不在这份方案里引入转码；如果重打包仍无法满足约束，应显式失败并记录原因。

## 4. 高层架构

推荐链路：

```text
FeaturePlayer
  -> PlaybackEngine
  -> Application PlaybackPackagingCoordinator
  -> Infrastructure PackagingWorkspaceRepository
  -> Swift 桥接层（`Bridge/CoreClient.swift`）
  -> Rust Packaging Service
  -> 本地打包 HLS/CMAF 工作目录
  -> 交付适配层
  -> AVPlayer
```

核心原则：

- `FeaturePlayer` 只拿到一个可播放的 master URL 和状态事件。
- `Application` 决定何时走打包路径、何时走普通路径。
- `Infrastructure` 管理工作目录、缓存、清理和诊断。
- 当前 `Bridge/CoreClient.swift` 负责 Swift 与 Rust 的 FFI 边界；若未来单独抽包，它才会演化成独立桥接模块。
- Rust 服务负责 probe、segment 规划、fragment 重组、playlist 生成和诊断输出。
- `DeliveryAdapter` 只负责把“已经打包好的工件”交给 AVPlayer，不负责媒体语义修补。

## 5. 输入合同

### 5.1 业务输入

打包器的业务输入统一抽象为一个 `PackagingRequest`：

```text
PackagingRequest
  assetId
  bvid
  cid
  quality
  requestedEngineKind
  videoTrack
  audioTrack?
  playbackMetadata
  cachePolicy
  diagnosticsPolicy
```

### 5.2 Track 输入

每条 track 至少提供：

```text
TrackInput
  primaryURL
  backupURLs[]
  codecString
  mimeHint
  bandwidthHint?
  durationMs?
```

### 5.3 playbackMetadata

用于 playlist 生成和验证的输入应至少包含：

```text
PlaybackMetadata
  width?
  height?
  frameRate?
  videoRange?
  colorPrimaries?
  transferFunction?
  matrixCoefficients?
```

### 5.4 技术输入来源

这份设计默认业务输入仍然来自现有 `video.playurl` / `PlayUrlDTO` 路径。

同时必须支持第二类输入：

- 已导出的 diagnostics 样本目录。

原因：

- diagnostics 输入是离线回归和生成验证的基础样本。
- 实时 upstream 输入是线上真实播放路径。

## 6. 输出合同

### 6.1 对 `PlaybackEngine` 的输出

打包器完成后，对上层统一输出一个 `PackagedPlaybackArtifact`：

```text
PackagedPlaybackArtifact
  masterURL
  workspaceRootURL
  deliveryKind
  streamManifestURL
  diagnosticsDirectoryURL
  startupReady
  cleanupToken
```

### 6.2 masterURL

`masterURL` 是唯一允许交给 AVPlayer 的播放入口。

优先顺序：

1. `file://.../master.m3u8`
2. 若 `file://` 在某类设备或场景下存在不可接受限制，可退到 `http://127.0.0.1/.../master.m3u8`

但无论最终交付适配层使用什么 URL，媒体语义都必须来自本地打包器输出，而不是来自实时 upstream byte-range 伪装。

### 6.3 工作目录结构

推荐固定为：

```text
Library/Caches/ibili-packaged-playback/<session-id>/
  master.m3u8
  video.m3u8
  audio.m3u8                 # 如存在独立音频
  init-video.mp4
  init-audio.mp4            # 如存在独立音频
  v-seg-00000.m4s
  v-seg-00001.m4s
  a-seg-00000.m4s           # 如存在独立音频
  stream-manifest.json
  authoring-summary.json
  diagnostics/
```

### 6.4 stream-manifest.json

这是内部诊断合同，不给 AVPlayer。

至少包含：

```text
streamManifest
  requestSummary
  videoPlan
  audioPlan
  segmentTable
  startupWindow
  detectedRisks
  validationStatus
```

## 7. 组件边界

### 7.1 FeaturePlayer

职责：

- 请求播放。
- 接收 `AVPlayerItem` 或 `masterURL`。
- 展示缓冲、失败、降级、重试和日志。

禁止：

- 直接解析 `sidx`。
- 直接决定 segment 边界。
- 直接操作 HLS playlist 文本。
- 直接调用 Rust FFI。

### 7.2 Application

建议新增一个协调器：

```text
PlaybackPackagingCoordinator
```

职责：

- 根据清晰度、codec、设备能力和历史失败记录决定是否进入打包路径。
- 统一调度实时请求、打包器、缓存工作区和 cleanup 生命周期。
- 对外只暴露 `preparePlayback(request:)` 这样的业务接口。

### 7.3 Infrastructure

建议新增：

```text
PackagingWorkspaceRepository
PackagedStreamCache
PackagingDiagnosticsStore
DeliveryAdapter
```

职责：

- 分配工作目录。
- 管理空间回收。
- 暴露本地文件或本地 HTTP 交付入口。
- 保存生成结果和失败诊断。

### 7.4 Swift Bridge

建议新增：

```text
PackagingBridgeClient
```

职责：

- 封装 FFI 入参和出参。
- 把 Rust JSON 或 DTO 解码成 Swift 结构。
- 隔离错误映射、取消、进度订阅和资源释放。

当前实现落点：

- `ios-app/IbiliApp/Sources/Bridge/CoreClient.swift`
- `packaging.offline_build`

禁止：

- 在 Swift bridge 层拼 HLS playlist。
- 在 Swift bridge 层决定 fragment 重写细节。

### 7.5 Rust Core

建议新增 service：

```text
ibili_core::playback_packaging
```

内部至少拆成：

```text
probe/
planner/
fetch/
fragment/
playlist/
validation/
diagnostics/
```

职责：

- 解析 init、`sidx`、sample entry、时间线元数据。
- 建立 segment 规划。
- 下载或拼接起播窗口所需的 upstream 片段。
- 输出本地 init、segment 和 playlist。
- 记录生成风险。

## 8. 打包流水线

### 阶段 1：source probe

目标：不播放，只建立真实结构认知。

至少完成：

1. 拉取 video/audio 头部窗口。
2. 解析 `ftyp`、`moov`、`sidx`、sample entry、color/HDR 信息，以及 `hvcC` / `dvvC` 这类 codec configuration box。
3. 识别是否存在独立 audio track。
4. 收集 `sidx` 的 SAP 信息。

### 阶段 2：segment planning

这是长期方案的关键。

规则：

- 不允许把 upstream `sidx` reference 直接等价为 HLS segment，除非 packager 能证明它满足独立起播要求。
- 对 video 而言，每个输出 segment 都必须从随机接入点开始。
- 如果一个 upstream reference 不能独立起播，packager 必须把多个 upstream reference 合并成一个输出 segment，直到下一个可接受边界。
- 如果无法证明 segment 独立性，就不能发布该 segment。

### 阶段 3：起播窗口打包

在把 URL 交给 AVPlayer 之前，至少要准备好：

1. `master.m3u8`
2. video `init`
3. audio `init`（如存在）
4. 第一批可独立起播的 video segment
5. 对应的 audio segment
6. 初始生成校验结果

明确要求：

- 不能像当前实时代理那样在“不确定 segment 是否可播”时就把 playlist 交给 AVPlayer。

### 阶段 4：background continuation

在起播窗口之后，可以继续后台打包后续 segment。

要求：

- playlist 更新必须单调追加。
- 不能回写已发布 segment 的时间线含义。
- 如果后续 segment 无法满足约束，应停止继续发布并显式失败，而不是静默给 AVPlayer 喂风险数据。

## 9. 关键生成规则

### 9.1 master playlist

必须准确输出：

- `CODECS`
- `SUPPLEMENTAL-CODECS`（向后兼容的 Dolby Vision 8.1 / 8.4 等场景）
- `RESOLUTION`
- `FRAME-RATE`
- `VIDEO-RANGE`（HDR / DV 相关场景）
- 独立 audio group（如存在）

额外规则：

- 对向后兼容的 Dolby Vision 8.x 流，`CODECS` 必须写基础层 codec，`SUPPLEMENTAL-CODECS` 才写 Dolby Vision codec。
- `VIDEO-RANGE` 不能由 qn 或 codec 前缀直接猜测，必须优先来自 init 的 sample entry / codec configuration 解析结果。
- 同一 asset 的 audio/video media playlist 必须共享一致的 `TARGETDURATION`。

### 9.2 media playlist

规则：

- 只在 packager 能证明所有输出 segment 都独立起播时，才允许写 `#EXT-X-INDEPENDENT-SEGMENTS`。
- `EXT-X-MAP` 必须指向本地 packager 产出的 init，不再指向 upstream blob 的 byte-range 片段。
- 输出 segment 名称和序号必须稳定，不允许复用旧路径表达不同语义。

### 9.3 fragment 语义

长期方案必须把下面这些点视为一级合同，而不是调试细节：

- `tfhd`
- `tfdt`
- `trun`
- first-sample flags
- sample dependency
- composition offsets
- timeline continuity

## 10. 失败语义

打包器的失败必须是确定性的。

允许的失败原因包括：

- 无法证明起播 segment 独立起播。
- fragment timeline 不连续。
- HDR / HEVC signaling 不满足作者侧要求。
- 生成的 HLS/CMAF 工件未通过本地结构校验。

禁止的失败方式：

- 明知结构不确定，仍把 URL 交给 AVPlayer 试试看。
- 播放失败后才补记“其实第一段不独立”。

## 11. 验证标准

### 11.1 结构验证

每次改动至少要覆盖：

1. Rust 单元测试：`sidx`、SAP、segment planner、playlist 生成。
2. Swift 单元测试：工作目录管理、交付适配层、错误映射。
3. diagnostics fixture 回归：qn125 失败样本、qn120 成功样本。

### 11.2 生成验证

对生成的本地 HLS 工件，至少要求：

1. `mediastreamvalidator` 无媒体级必须修复错误。
2. `hlsreport --rule-set ios` 不出现由打包器新引入的高严重度回归。
3. 输出的 `authoring-summary.json` 必须记录每个 playlist 和 segment 的校验状态。

### 11.3 真机行为验证

第一阶段验收标准：

1. qn125 在最小 AVPlayer harness 中可起播。
2. qn125 在 app 内正式播放路径可起播。
3. qn120 等已成功样本无回归。
4. 不再依赖当前 live `sidx -> HLS BYTERANGE` 语义。

### 11.4 性能验证

第一阶段可以接受有额外起播成本，但必须量化。

至少记录：

- 起播准备时间
- 首帧时间
- 起播窗口字节数
- packaged segment count
- 工作目录大小

长期目标：

- qn125 路径的额外代价可观测、可优化，而不是黑盒等待。

## 12. 里程碑建议

### M1：离线打包器

输入：diagnostics 样本目录。

输出：本地 HLS/CMAF 工作目录。

当前实现状态：

- 已落地 `packaging.offline_build`（Rust core / FFI / Swift bridge）。
- 当前会把 proxy diagnostics 或 remux diagnostics 规范化到本地 `packaging-workspace/`。
- 当前会实际写出 `master.m3u8`、`video.m3u8`、`audio.m3u8`（若有音频）、`stream-manifest.json`、`authoring-summary.json`。
- 当前是“起播窗口 diagnostics 构建”，目标是 AVPlayer 本地冒烟验证，不是完整长视频生成。

目标：

- 完全脱离实时代理。
- 把 qn125 / qn120 的差异收敛到打包器层。

### M2：app 内文件工作区播放

输入：真实 `PlayUrlDTO`。

输出：本地工作区 + AVPlayer 可播 `masterURL`。

目标：

- 在 app 内跑通起播窗口打包。
- 暂时只覆盖高风险 HEVC/HDR 变体。

### M3：统一播放入口

目标：

- 把普通可播流和高风险流收敛到同一套正式打包 / 交付架构。
- 逐步淘汰语义上不可控的实时代理路径。

## 13. 这份设计约束的直接含义

如果后续有人再次提出下面这些方向，应直接回到本文件核对：

- “要不要再 patch 一下 `init.mp4`？”
- “要不要继续试试 FFmpeg HLS muxer 参数？”
- “要不要先用整文件下载顶一下？”

这些都不满足这份设计的长期合同。

符合这份设计的唯一方向是：

- 建立一个真正受控的 Apple 兼容 HLS/CMAF 打包器。

## 14. 相关文档

- `docs/ios-remux-fallback-debug-notes.md`
- `docs/ios-workspace-architecture.md`
- `docs/rust-core-swift-bridge-interface-design.md`