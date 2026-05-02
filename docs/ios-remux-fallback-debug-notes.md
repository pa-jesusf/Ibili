# iOS qn125 AVPlayer 路径问题记录

## 状态

这条问题线已经完成一次足够明确的收敛。

- 当前结论写于 2026-05-02。
- 这份文档的职责是记录已经证伪的方向，以及后续必须坚持的长期路线。
- 任何已经回滚的实验性代码都不应因为“也许再补一刀就行”而被重新恢复。

## 已验证事实

同一素材上，目前有四条已经拿到证据的结论：

1. qn125 在 app 内当前 `HLSProxyEngine -> LocalHLSProxy -> AVPlayer` 路径上仍会报 `CoreMediaErrorDomain -12927`。
2. 这个失败不是只停在 `init.mp4` 阶段；AVPlayer 已经请求到首个 media fragment 后仍然失败。
3. streaming FFmpeg remux fallback 也不能把 qn125 救回来；它同样会在 `init.mp4 + seg-0.m4s` 之后报 `-12927`。
4. 同一份 qn125 样本经过离线 Apple 风格 HLS 重打包后，可以在最小 AVPlayer harness 中起播；历史上整文件先下载完再播也验证过可以工作。

这四点合在一起，足以说明：

- qn125 不是“天生不能被 AVPlayer 播放”。
- 当前失败集中在 app 内 live 分片交付路径，而不是一个简单的 init box 命名问题。

## 已被证伪的方向

下面这些方向已经不应该继续作为主线投入：

- 继续围绕 `init.mp4` 做小修小补，例如 `edts/elst`、`ftyp`、`hvc1/hev1`、`CODECS` 字段微调。
- 继续在 `LocalHLSProxy` 的 `sidx -> HLS BYTERANGE` 伪装路径上追加局部 patch，期待“再补一个 box”就能让 qn125 起播。
- 继续把 FFmpeg live remux 当作主线解法，尤其是继续做 HLS muxer 参数摸奖式调参。
- 把“自动降到 qn120”或“整文件先下完再播”误记为问题已经解决。

这些尝试的共同问题是：它们都不能从根上提供一个真正由我们控制、且满足 Apple 预期的 segment 打包结果。

## 2026-05-02 新增踩坑记录：Dolby Vision 8.4 / HLG

在 qn125 之外，后续又定位到一类单独的 Dolby Vision 样本坑点，必须单独记住：

- 不能把 `qn=125/126` 当作 `PQ` 的可靠信号。至少有一类 `dvh1.08.xx` 样本真实是 HLG，而不是 PQ。
- 不能把 backward-compatible Dolby Vision 8.x 流直接 author 成 `CODECS="dvh1..."`。Apple 推荐的写法是：
	- `CODECS` 写 base layer，例如 `hvc1...`
	- `SUPPLEMENTAL-CODECS` 写 Dolby Vision 增强信息，例如 `dvh1.08.09/db4h`
- 不能让 `playurl` 的粗粒度 hint 覆盖 init sample entry 的真实解析结果。`hvcC` / `dvvC` / color metadata 才是更高优先级的 authoring 依据。
- audio/video media playlist 的 `TARGETDURATION` 不能各写各的；Apple validator 会把这种差异判成 must-fix。

这类问题的本质已经不是“AVPlayer 会不会解 Dolby Vision”，而是“我们有没有把 backward-compatible Dolby Vision author 成 Apple 期望的 HLS 形式”。

## 根因边界

当前最合理的边界判断是：

- 问题在 fragment / segment 级别的交付语义。
- 剩余高价值嫌疑点包括：随机接入边界、`sidx` 的 SAP 信息、`tfhd/tfdt/trun`、sample flags、composition offsets，以及 HEVC parameter sets / SEI / HDR signaling。
- 也就是说，问题已经从“patch 一个 init box”收敛为“当前 live segment packaging 不满足 AVPlayer 对 Apple 风格 HLS/fMP4 的要求”。

## 长期方案决策

后续不妥协的长期方向只有一个：

- 为 AVPlayer 提供真正 Apple-compatible 的 HLS/CMAF 打包结果，并且 segment 语义由打包层明确控制。

这条路线的含义是：

- 优先考虑上游直接提供可被 AVPlayer 接受的 Apple 风格 HLS/CMAF。
- 如果上游拿不到，就需要单独的正式打包层来重组视频 segment，而不是继续沿用当前的 live `sidx -> HLS BYTERANGE` 代理伪装。
- 这个打包层必须能明确决定或重写 fragment 级结构，而不是只在端上零碎改 `init.mp4`。

## 明确的非方案

为了避免以后再踩同一个坑，下面这些只能视为止损或诊断手段，不能写进长期架构：

- 自动降档。
- 先整文件下载再播。
- 失败后临时切到别的清晰度。
- 继续堆叠本地代理 patch。
- 继续把 FFmpeg live remux 作为 qn125 的主线修复方案。

## 如果未来必须重启这条问题线

只能从下面这组对照开始，而不是再回到 init patch：

1. 比较 qn125 失败片段与 qn120 成功片段的 `sidx` SAP 信息。
2. 比较 `tfhd`、`tfdt`、`trun`、first-sample flags、composition offsets。
3. 比较 HEVC parameter sets、SEI、HDR 静态元数据与 color signaling。
4. 确认 segment 边界是否真的对齐随机接入点。

## 相关文档

- `docs/ios-avplayer-packaging-implementation-design.md`
- `docs/ios-avplayer-offline-packaging-validation.md`
- `docs/ios-workspace-architecture.md`
