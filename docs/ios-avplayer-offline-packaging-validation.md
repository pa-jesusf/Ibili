# iOS AVPlayer 离线打包验证

## 目的

这个实验不是继续在本地代理里猜 box，而是把一次失败播放导出的样本重新打包成更接近成熟 Apple 交付路径的 fMP4 HLS，然后回答一个更硬的问题：

```text
如果把同一份 qn125 样本离线重打包成 Apple 风格 HLS，AVPlayer 还会不会拒绝？
```

如果这一步都失败，说明问题大概率不在 localhost 代理，而在源流的 HEVC Main10 HDR/PQ signaling 或 bitstream 语义本身。

## 已验证结论（2026-05-02）

这份验证链路已经给出两个足够硬的结论：

- 同一份 qn125 样本离线重打包成 Apple 风格 HLS 后，可以在最小 AVPlayer harness 中起播。
- 后续修复已经让 app 内当前的 live HLS 代理路径也能起播这类样本；streaming FFmpeg remux fallback 则已被彻底移除。

这意味着：

- qn125 并不是“天生不能被 AVPlayer 播放”。
- 先前的失败边界确实收敛在 authoring / segment 交付语义，而不是素材本身不可播。
- 修复方向应该集中在 HLS authoring 正确性，而不是继续扩张备用引擎、remux fallback 或额外调试回放路径。

## 2026-05-02 补充：Dolby Vision 8.4 / HLG 样本的真实修复点

后续对 `aid=785674172 / cid=1192193741 / qn=126` 的 diagnostics 样本又给出了一条更细的结论。

这个样本不是前面的 HEVC PQ 失败重演，而是一条 Dolby Vision 8.4 / HLG 兼容流：

- `playurl` 返回的 video codec 是 `dvh1.08.09`。
- 但 `video-init.mp4` 的 sample entry 实际是 `hvc1`，同时带 `dvvC`。
- Apple `mediastreamvalidator` 对旧 authoring 的明确报错是：
  - playlist codec type 写成了 `dvh1`，但内容 codec type 是 `hvc1`
  - `VIDEO-RANGE` 被写成了 `PQ`，但片段真实 transfer function 是 `HLG`
  - audio/video media playlist 的 `TARGETDURATION` 不一致

这条样本最后验证下来的正确 authoring 规则是：

- `CODECS` 必须写 base layer codec，而不是直接写 `dvh1.08.09`
- `SUPPLEMENTAL-CODECS` 必须写 Dolby Vision codec，例如 `dvh1.08.09/db4h`
- `VIDEO-RANGE` 必须和 Dolby Vision compatibility id 以及真实 transfer function 一致；这条样本应是 `HLG`，不是 `PQ`
- audio/video media playlist 必须共享同一个最大 `TARGETDURATION`

换句话说，这类 backward-compatible Dolby Vision 8.x 样本不能只看 `playurl` 的 codec 名，也不能只看 qn，就把 master playlist 写出来。必须从 init 里的 `hvcC` / `dvvC` 和颜色信息反推出真正的 Apple-compatible authoring。

## 已落地的修复要点

当前仓库已经把下面这些点固化进实现：

- 运行时只保留 live HLS proxy 一条播放路径；播放失败时会自动导出 diagnostics 并生成 `packaging-workspace/`
- diagnostics 导出目录现在只保留最近 5 份，避免失败样本无限堆积
- HLS authoring 会优先使用 init probe 解析出的 video metadata，而不是盲信 `playurl` hint
- 对 Dolby Vision 8.4 / HLG 样本，master playlist 会写 base `hvc1` codec + `SUPPLEMENTAL-CODECS="dvh1.../db4h"` + `VIDEO-RANGE=HLG`
- offline packaging 输出的 audio/video playlist target duration 会对齐到同一个值
- FFmpeg remux fallback 和 in-app diagnostics browser 都已从当前代码路径移除

## 为什么这个实验比继续 patch localhost 更有价值

Apple 官方和成熟打包平台给出的路线是统一的：

- Apple 端 HEVC/HDR 应该走 fMP4 HLS。
- 最好把 video/audio 作为独立轨道与独立 Media Playlist 提供。
- `EXT-X-MAP`、`CODECS`、`RESOLUTION`、`FRAME-RATE`、`VIDEO-RANGE` 这些作者侧信号要完整。
- 真正成熟的系统是在打包层把 CMAF/HLS 做对，而不是在 iOS 端临时修流。

这份实验脚本就是把现有 diagnostics 样本推向这个方向，先做一个最小可证伪的离线验证。

## 输入要求

复现一次 qn125 失败并触发 app 内 diagnostics 导出后，导出目录里应至少包含：

- `video-init.mp4`
- `video-fragment-000.m4s`
- `metadata.json`
- `audio-init.mp4`（若有独立音频）
- `audio-fragment-000.m4s`（若有独立音频）

当前 app 会在同一个 diagnostics 目录里自动继续执行一次 `packaging.offline_build`，生成 `packaging-workspace/` 作为后续 AVPlayer smoke test 输入。

典型目录：

```text
ibili-diagnostics/hls-2026-.../
ibili-diagnostics/baseline-2026-.../
```

## 当前仓库状态

当前 checkout 已经不再包含 `tools/validate_apple_hls_offline.sh`。

历史 `apple-hls-offline/` 目录仍可作为“离线 Apple 风格 HLS 曾被验证通过”的证据保留，但当前仓库里的正式实现入口已经改成：

- Rust core / FFI 方法：`packaging.offline_build`
- Swift bridge：`CoreClient.packagingOfflineBuild(diagnosticsDirectory:outputRootDirectory:)`

这个入口会在 diagnostics 目录下生成 `packaging-workspace/`，其中包含：

```text
packaging-workspace/
  master.m3u8
  video.m3u8
  audio.m3u8            # 若样本含独立音频
  init-video.mp4
  v-seg-00000.m4s
  init-audio.mp4        # 若样本含独立音频
  a-seg-00000.m4s       # 若样本含独立音频
  stream-manifest.json
  authoring-summary.json
  diagnostics/
```

这份 workspace 的定位是：

- 让 AVPlayer 对同一份 diagnostics 样本做本地 smoke test。
- 验证 packager 输出语义，而不是继续依赖历史脚本或 live proxy。
- 当前只覆盖 startup window diagnostics，不代表完整长视频 packaging 已完成。

## 历史脚本产物（仅供参考）

```text
apple-hls-offline/
  video.m3u8
  video-iframe.m3u8
  audio.m3u8                # 如果存在音频样本
  video.mp4
  audio.mp4                # 如果存在音频样本
  video-ffprobe.json
  audio-ffprobe.json       # 如果存在音频样本
  master-summary.json
  mediastreamvalidator.txt
  validation_data.json
  hlsreport.txt
  hlsreport-ios.html
  master-url.txt
  README.txt
```

## 历史脚本具体做了什么

1. 读取一次失败播放导出的 diagnostics 样本。
2. 重新组织成更接近 Apple 风格 fMP4 HLS 的本地工作区。
3. 生成 `master.m3u8`、video/audio media playlist 与配套 manifest。
4. 用这份工作区继续做 AVPlayer 与 authoring 侧验证。

注意：这一步故意不依赖 app 内的 localhost proxy。它要验证的是“样本本身经过更标准的打包后，AVPlayer 还拒不拒绝”。

## 结果判读

### 情况 1：`mediastreamvalidator` 或 `hlsreport` 报 HLS/CMAF 作者侧错误

结论：

- 问题已经从“播放器怪癖”收敛到“打包/信号不合 Apple 约束”。
- 后续应优先修正离线打包链路，再决定是否把同类修正前移到上游。

### 情况 2：离线 HLS 正常，最小 AVPlayer harness 能起播

结论：

- qn125 样本并非绝对不能被 AVPlayer 接受。
- 当前 app 内 live 交付路径才是主要嫌疑点，尤其是 segment authoring、fragment 边界语义、以及 AVPlayer 对 Apple 风格 HLS/fMP4 的期望。
- 这一步的正确后续不是继续 patch localhost proxy，而是转向长期方案：真正提供 Apple-compatible HLS/CMAF 打包结果，且 segment 语义由打包层明确控制。

### 情况 3：离线 HLS 依然被 AVPlayer 拒绝

结论：

- 继续 patch `hvc1/hev1`、`ftyp`、`elst` 这种表层结构的收益会很低。
- 下一主线应转向 bitstream/HDR/Main10/PQ signaling 本身，尤其是 `hvcC` 与 HDR 静态元数据。

## 推荐的对照方式

同一素材至少跑两次：

1. `hls-...` 或失败导出目录，对应 qn125。
2. `baseline-...` 成功导出目录，对应 qn120 或其它可播档位。

然后比较两边的：

- `master-summary.json`
- `video-ffprobe.json`
- `mediastreamvalidator.txt`
- `hlsreport-ios.html`

这样能直接看出“Apple 风格打包后，qn125 相比 qn120 还剩什么不可消除的差异”。

## 局限性

- 当前样本只包含 init 加前几个 fragment，回答的是“能否起播”，不是长时间播放稳定性。
- 如果 `mediastreamvalidator` 未安装，脚本只能做到“生成更标准的 HLS + 本地服务 + 元数据整理”，还不能替代 Apple 官方校验。
- macOS Safari / macOS AVFoundation 的结果有参考价值，但不能完全等同于真机 iOS。

## 下一步建议

如果离线 Apple 风格 HLS 能播，而 app 内 live 路径仍然失败，后续主线应该直接升级到长期方案，而不是继续打补丁：

1. 把目标收敛为“获得 Apple-compatible HLS/CMAF 输出”，优先考虑上游或专门打包层，而不是继续沿用当前 `sidx -> HLS BYTERANGE` 代理伪装。
2. 若必须继续技术验证，应直接比较 qn125 与 qn120 的 fragment 级差异：`sidx` 的 SAP 信息、`tfhd/tfdt/trun`、sample flags、composition offsets，以及 HEVC parameter sets / SEI / HDR signaling。
3. 不要把“整文件先下完再播”或“自动降档”误记为解决方案；它们只能算临时止损，不是长期架构方向。