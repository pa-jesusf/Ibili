# iOS 播放器 Remux Fallback 问题追踪

## 当前目标

为 B 站 DASH 高画质 / HEVC / HDR / Dolby Vision 变体实现透明、按需、非全量下载的 remux fallback：

```text
B 站 CDN video fragments -> 本地 pipe -> 长生命周期 FFmpeg remux -> fMP4 HLS -> LocalHLSProxy -> AVPlayer
```

要求：

- 不全量下载。
- 不后台无脑全量下载。
- 不每个 segment 启动一次 FFmpeg。
- 普通视频继续走原有 `HLSProxyEngine`。
- 只对 AVPlayer 拒绝的变体走 remux fallback。
- 尽量保留原生 AVPlayer、进度条、PiP、AirPlay。

## 现状

正常 HLS proxy 路线对普通 H.264 / 普通 HEVC 视频可用，但部分 qn=125 高画质 / HDR / HEVC Main10 视频在 AVPlayer 阶段失败：

```text
CoreMediaErrorDomain -12927
```

当前 remux fallback 已经推进到：

```text
video-only named pipe -> ibili_remux_hls_live -> init.mp4 + live.m3u8 + seg-0.m4s... -> /remux/<token>/... -> AVPlayer
```

音频暂时没有进入 FFmpeg pipeline，后续应继续走原始 HLS byte-range pass-through。

## 已验证失败阶段

2026-05-01 最新真机日志已经把失败边界推进到了首个 media fragment，且 direct HLS 与 remux 两条路都失败。

### direct HLS 路线

AVPlayer 已经不再只停在 init 阶段，而是会继续请求：

```text
/play/<token>/master.m3u8
/play/<token>/video.m3u8
/play/<token>/v.init
/play/<token>/v.seg (首片段 range)
```

并且已经验证过：

- patched init 已去掉 `edts/elst`。
- sample entry 已改成 `hev1`。
- `ftyp` 已带 `cmfc` 兼容品牌。
- 首片段诊断显示 top-level boxes 为 `moof,mdat`。

但 AVPlayer 仍然报：

```text
AVPlayerItem 失败 | CoreMediaErrorDomain -12927
```

### remux fallback 路线

remux 路线现在会完整请求：

```text
/remux/<token>/master.m3u8
/remux/<token>/audio.m3u8
/remux/<token>/video.m3u8
/remux/<token>/init.mp4
/remux/<token>/seg-0.m4s
```

并且已经验证过：

- remux patched `init.mp4` 已去掉 `edts/elst`。
- `ftyp` 已从 `iso5/...` 归一化到 `iso6 + cmfc`。
- sample entry 已从 `hvc1` 改成 `hev1`。
- remux master 已补上 `CODECS` 与独立 audio group。
- `seg-0.m4s` 已被 AVPlayer 请求，首片段 top-level boxes 为 `styp,sidx,moof,mdat`。

但在请求到 `seg-0.m4s` 后，AVPlayer 仍然报：

```text
AVPlayerItem 失败 | CoreMediaErrorDomain -12927
```

### 同素材对照结论

同一视频已验证：

- `qn=125` 的 `hvc1.2.4.L153.90` 变体在 direct HLS 和 remux 两条路都失败。
- 自动降到 `qn=120` 后，`hev1.1.6.L153.90` 变体可正常播放。

结论：

- “只要修 init.mp4 就能救回 qn=125” 这个假设已经被证伪。
- `edts/elst` 不是唯一根因，甚至很可能不是当前主因。
- 继续在 FFmpeg HLS muxer 参数和 init patch 上追加小修小补，收益已经很低。

## remux init.mp4 诊断结果

设备日志中 `remux init.mp4 诊断` 显示：

```text
sampleEntries=hvc1
hasHvcC=true
hvcC=version=1,profileSpace=0,tier=0,profileIDC=2,compat=0x20000000,levelIDC=153
hasDvcC=false
hasDvvC=false
allBoxTypes=ftyp,moov,mvhd,trak,tkhd,edts,elst,mdia,mdhd,hdlr,minf,vmhd,dinf,dref,stbl,stsd,hvc1,hvcC,colr,pasp,btrt,stts,stsc,stsz,stco,mvex,trex,udta
```

macOS 上对导出的 `remux-2026-04-29T12-00-54.159Z-b9844348` 目录运行 `debug-on-macos.sh` 后，`ffprobe` 可正常解析：

```text
Video: hevc (Main 10) (hvc1), yuv420p10le(tv, bt2020nc/bt2020/smpte2084), 3840x2160, level 153
```

说明：

- `hvcC` 存在，不是缺 decoder config。
- sample entry 已是 `hvc1`。
- 未发现 `dvcC/dvvC` Dolby Vision config box。
- 视频是 4K HEVC Main10 HDR PQ：`bt2020nc/bt2020/smpte2084`。

## 当前最重要结论

这轮踩坑后，已经可以确认下面几点：

- `edts/elst` 去除是必要排查项，但不是充分条件。
- `ftyp` 品牌归一化、`hvc1/hev1` sample entry 改写、master playlist `CODECS` 修正，都不足以让 qn=125 起播。
- 失败边界已经从“init 是否被接受”推进到“首媒体段之后仍报 -12927”。
- remux fallback 当前还会额外引入接近 9 秒的失败等待成本，因此不应该继续作为主线修复方案。

这意味着问题更可能在下面这些层面之一：

- qn=125 这条 HEVC Main10/HDR 变体本身的 fragment/timeline 语义。
- AVPlayer 对该变体的 `moof/traf/tfhd/tfdt/trun` 组合要求。
- 该素材在本地 HLS byte-range / remux 两种包装下都会触发的更深层 CoreMedia 兼容性问题。

当前产品侧保留“自动跳过已知坏档位并降到 qn=120”只是止损措施，不是最终解决方案。

## 已尝试 / 已改动

### 1. 诊断导出

remux fallback 失败时现在会导出到：

```text
Documents/ibili-diagnostics/remux-<timestamp>-<workspace-prefix>/
```

典型内容：

```text
AVFoundationProbe.swift
debug-on-macos.sh
init.mp4
live.m3u8
local.m3u8
metadata.json
seg-0.m4s
```

`local.m3u8` 会把绝对路径改成相对路径，方便拷贝到 macOS 后调试。

### 2. 恢复策略

remux fallback 失败后不再重复尝试同一个 qn 的原始 HLS。现在应直接 block 当前 qn 并降档，避免：

```text
qn=125 hls_proxy 失败 -> remux 失败 -> qn=125 hls_proxy 再失败 -> 降档
```

此外，针对当前已经反复验证的坏组合：

- 自动模式会主动避开 `qn=125 + HEVC profileIDC=2` 这一已知坏档位。
- 如果用户手动点进这个档位并仍然触发 `-12927`，播放器会跳过已经证实无效的 remux 尝试，直接进入降档恢复。

注意：这是临时止损，不代表 qn=125 的问题已经解决。

### 3. C wrapper muxer 参数

在 `ios-app/ThirdParty/ffmpeg/wrapper/FFmpegRemux.c` 的 `ibili_remux_hls_live` 中加入了：

```c
av_dict_set(&mux_opts, "movflags", "+frag_keyframe+empty_moov+default_base_moof+negative_cts_offsets", 0);
av_dict_set(&mux_opts, "use_editlist", "0", 0);
```

注意：macOS 上用 FFmpeg CLI 对照测试时，`-use_editlist 0` 对 HLS fMP4 muxer 未必能去掉 `edts/elst`。所以这一步需要在 iOS framework 重编后验证，但不能假设一定有效。

### 4. 代理层 / Rust patch 尝试结果

已经实际做过并验证过的 patch 包括：

- 删除 init 中的 `edts/elst` 并回写父 box size。
- `ftyp` 品牌归一化到 `iso6/cmfc`。
- sample entry 从 `hvc1` 改成 `hev1`。
- direct HLS 改成单独 `v.init`，避免长度变化的 init patch 继续塞回 `v.seg`。
- remux master playlist 补齐 `CODECS`、audio group，并移除 `INDEPENDENT-SEGMENTS` 宣告。
- 增加 direct HLS 与 remux 的首片段盒结构诊断。

结果：上述改动都不足以让 qn=125 成功播放。

## 构建注意事项

`./tools/build_unsigned_ipa.sh` 只做：

1. Rust XCFramework 构建。
2. Xcode project 生成。
3. `xcodebuild archive`。
4. unsigned IPA 打包。

它不会重编 `ios-app/Frameworks/FFmpegRemux.xcframework`。

如果只改了 Swift，运行：

```bash
./tools/build_unsigned_ipa.sh
```

即可。

但如果改了：

```text
ios-app/ThirdParty/ffmpeg/wrapper/FFmpegRemux.c
ios-app/ThirdParty/ffmpeg/wrapper/Headers/FFmpegRemux.h
```

需要先重编 `FFmpegRemux.xcframework`，再打 IPA。

完整重编脚本：

```bash
bash ios-app/ThirdParty/ffmpeg/build-ffmpeg-ios.sh
./tools/build_unsigned_ipa.sh
```

`build-ffmpeg-ios.sh` 会从 tracked wrapper 目录拷贝源码：

```text
ios-app/ThirdParty/ffmpeg/wrapper/FFmpegRemux.c
ios-app/ThirdParty/ffmpeg/wrapper/Headers/FFmpegRemux.h
ios-app/ThirdParty/ffmpeg/wrapper/Headers/module.modulemap
```

再生成：

```text
ios-app/Frameworks/FFmpegRemux.xcframework
```

## 下一步建议

### 新决策

后续主线不再继续追加“FFmpeg HLS muxer 参数微调 + init patch”这一方向。

原因很直接：这条路已经经过 direct HLS 和 remux 两套实测，失败边界也已经推进到首片段之后，继续在 init 层做文章不再有足够的证据支撑。

### 采纳方案 B：不用 FFmpeg HLS muxer，改为自定义 fMP4 输出

后续应该把文档中的方案 B 升级为主线：

```text
init.mp4 + moof/mdat segments + 自己生成 m3u8
```

这里的重点不是“再做一次 init patch”，而是获得对 fragment 级别语义的完整控制权，至少要能确定或重写：

- `tfhd/tfdt/trun` flags 与 composition offsets。
- sample dependency / default sample flags。
- 是否需要保留、剥离或重建某些 fragment-level box。
- timeline 连续性与 AVPlayer 对首段的期望。

音频仍可继续走现在已稳定的原始 pass-through 路线；真正需要重做的是 qn=125 视频轨的打包器，而不是再围绕 FFmpeg HLS muxer 打补丁。

### 方案 A：代理层 patch init.mp4

方案 A 现在降级为：

- 有价值的诊断手段。
- 局部兼容性实验手段。
- 但不再是主线修复方案。

### 临时止损策略

在方案 B 落地前，可以保留当前的产品止损逻辑：

- 自动模式主动跳过已知坏的 `qn=125` 组合。
- 手动选中后失败则直接降到下一个可播档位。

这只是保证用户能看，不应被误记为“问题已解决”。

### 后续排查重点

下一轮如果继续做技术验证，不应再优先看 `edts/elst`，而应直接比较：

```text
qn=125 失败片段 vs qn=120 成功片段
```

重点关注：

- `tfhd/tfdt/trun` 字段差异。
- composition time offset / B-frame 相关信息。
- fragment 首段 flags 是否存在 AVPlayer 特别敏感的组合。
- qn=125 与 qn=120 在 profile、color、timeline 之外的结构差异。

  

> 注意：以下长段“Rust 内存级二进制修补”内容是阶段性提案，不再作为当前执行结论。
>
> 2026-05-01 的真机验证已经证伪了它的核心假设：即使去掉 `edts/elst`、重写 `ftyp` 品牌、修正 `hvc1/hev1` sample entry，并让 AVPlayer 请求到首个 media fragment，`qn=125` 仍会在 direct HLS 与 remux 两条路径上报 `CoreMediaErrorDomain -12927`。
>
> 这部分内容保留仅作为历史存档，不应继续被当作“最终路线”执行。

  
  这是一份为你量身定制的**深度扩充版架构实施文档**。这次我大幅增加了“架构演进背景”、“踩坑血泪史”以及“技术选型底层逻辑”的篇幅。
  这不仅是一份给 AI Agent 的执行指令，更是你们项目在底层播放器架构上历经无数次推倒重来后，沉淀下来的极其宝贵的**技术决策记录（ADR - Architecture Decision Record）**。
  你可以直接将其作为最高级别的 Prompt 交给后续的开发 Agent。

  # 架构实施规范：iOS AVPlayer DASH fMP4 内存级二进制修补与兼容方案
  ## 一、 业务背景与终极架构博弈 (Background & The Architectural Dilemma)
  **1. 核心矛盾：上游数据 vs. 下游引擎**
  本项目（Ibili）致力于打造体验极致的第三方 iOS Bilibili 客户端。目前面临的最深水区挑战，在于**上游 B 站下发的数据流与苹果 iOS 系统原生播放引擎之间的底层冲突**。
   * **B 站数据流（DASH）：** 采用音视频物理分离的 fMP4 (Fragmented MP4) 格式，包含 4K、HEVC (H.265) Main10、HDR10 (PQ) 及杜比视界等顶级画质变体。并且，其视频编码常带有复杂的 B 帧参考和负向时间戳偏移（negative_cts_offsets）。
   * **苹果原生引擎（AVPlayer）：** 为了保留 iOS 系统级的画中画（PiP）、AirPlay 投屏、锁屏控制，以及利用 VideoToolbox 达到极佳的功耗控制，我们**必须**死守 AVPlayer。但 AVPlayer 对播放列表和 fMP4 容器的元数据有着极其严苛（甚至可以说是死板）的规范要求（Apple HLS Authoring Specification）。
  **2. 核心报错：致命的 -12927**
  为了强行撮合这两者，我们在端上架设了 **Local HTTP Proxy（本地代理）**，将 DASH 映射为 HLS（.m3u8）。但当 AVPlayer 请求到 B 站的初始化分片（init.mp4）时，由于文件头部存在不合规的 Box 结构，CoreMedia 解码器会直接拒绝注册，抛出 CoreMediaErrorDomain -12927 (kCMFormatDescriptionError_InvalidFormatDescription) 错误，导致视频彻底黑屏。
  ## 二、 踩坑血泪史：为什么我们排除了其他所有路线？ (The Pitfalls & Lessons Learned)
  在得出最终结论前，我们几乎把业界所有主流的音视频填坑方案都试错了一遍，并付出了惨痛的代价。后续开发**绝对禁止**重走以下死胡同：
  ### ❌ 踩坑 1：退回 AVMutableComposition 拼合轨道
   * **尝试：** 不写 Proxy，直接在端上用苹果官方 API 把分离的音视频轨道拼起来。
   * **死因（木桶效应）：** AVPlayer 强制要求两路流必须双双完成网络元数据加载并严格对齐后才能起播。一旦某路网络轻微波动，就会死锁在黑屏转圈。起播时间长达几秒甚至几十秒，完全丧失了“秒开”体验。
  ### ❌ 踩坑 2：替换底层内核（引入 ijkplayer / VLC 等跨平台引擎）
   * **尝试：** 彻底抛弃 AVPlayer，用基于 FFmpeg 软解/硬解的第三方引擎接管播放。
   * **死因（体验降级）：** 这是向系统生态投降。跨平台播放器会直接导致 iOS 原生画中画（PiP）报废、AirPlay 投屏黑屏无声；更致命的是，在播放 4K HDR 视频时无法完美对接苹果的 EDR 屏幕映射，导致发热严重、功耗翻倍。
  ### ❌ 踩坑 3：硬核推流 AVStreamDataParser
   * **尝试：** 用底层的 AVStreamDataParser 直接解包 DASH fMP4，配合 AVSampleBufferDisplayLayer 手动绘制画面。
   * **死因（时间轴灾难）：** B 站的 HEVC 包含极复杂的 B 帧。手动推流要求极度精确的音画时钟同步（PTS/DTS 偏移计算）。稍有不慎就会导致音频漂移、画面微卡顿，且依然不支持原生画中画和原生 HDR 映射。
    ### ❌ 踩坑 4：引入 FFmpeg 进行后台实时 Remux
     * **尝试：** 在本地起一个长生命周期的 FFmpeg 子进程，实时将 DASH 切片重封装为纯正的 HLS fMP4 输出。
     * **死因（不只是 Edit List）：** 一开始最可疑的是 FFmpeg 生成的 `edts/elst`，但后续真机验证已经证明问题比这更深。即使我们在代理层删除 `edts/elst`、归一化 `ftyp` 品牌、修正 `hvc1/hev1` sample entry，并让 AVPlayer 真正请求到 `seg-0.m4s`，`qn=125` 仍然在 direct HLS 与 remux 两条路径上报 `CoreMediaErrorDomain -12927`。因此这条路的根本问题不是“再多打一层 init patch”就能解决，而是 FFmpeg HLS muxer 与该类 Main10/HDR 片段在 AVPlayer 下的整体兼容性和时间线控制力都不够，且还会额外引入明显的起播失败等待成本。
  ### ❌ 踩坑 5：引入 Go 语言（mp4ff）进行本地处理
   * **尝试：** 听信偏向后端的架构建议，引入 Go 语言的 mp4ff 库做 Sidecar 进程或 CGO 调用。
   * **死因（移动端水土不服）：** iOS 严格的沙盒机制封杀了 Unix Domain Socket 跨进程通信。如果走 CGO 打包静态库，会强行塞入 15MB+ 的 Go Runtime。在极度要求低延迟的视频流代理环节，Go 的 GC（垃圾回收）停顿会导致严重的性能抖动。
    ## 三、 已被证伪的阶段性提案：Rust 内存级二进制修补 (Historical Proposal)
    当时的阶段性判断是：Local HTTP Proxy + Rust 内存级二进制零拷贝修补可能是主线方案。现在这条判断已经被实测否决，后续不应再把它当作唯一解。
   1. **坚持 Local Proxy：** 这是在不破坏 AVPlayer 黑盒的前提下，骗过系统、保留原生一切特性的唯一桥梁（传输层不变）。
   2. **不重转码、不重封装：** 我们不再试图改变视频流的时间轴，而是直接在极小的初始化元数据（init.mp4，通常仅几十 KB）上下手。
   3. **为什么是 Rust？** 我们的 core 层已经由 Rust 构建（ibili_core + ibili_ffi）。Rust 没有 GC 停顿，编译为 C-ABI 静态库后，内存占用极小、执行速度在 0.01 毫秒级。在 Swift 拦截到二进制 Data 后，直接将裸指针（Raw Pointer）传给 Rust 进行手术式篡改，实现真正的**零拷贝（Zero-Copy）**与绝对的内存安全。
  ## 四、 核心手术清单：二进制修补算法要求 (Binary Patching Algorithms)
  当 Rust 层的 FFI 接收到 init.mp4 的字节流时，必须且仅需执行以下精确打击操作：
  ### 1. 结构物理切除：根绝时间戳异常与 edts 报错
   * **目标：** 解决 FFmpeg 都去不掉的 Edit List 导致 -12927 的绝症。
   * **操作：** 遍历 Box 树至 moov -> trak -> edts。将整个 edts 字节块从内存中强行切除。
   * **一致性修正（极其关键）：** 切除后，必须向上回溯，将父容器 trak 以及祖父容器 moov 头部的 32-bit Size 字段（或 64-bit co64 标量），**精确减去**被切除的 edts 总字节数。否则后续解析将发生越界崩溃。
  ### 2. 标签强制篡改：破解硬件解码器审查
   * **目标：** 绕过苹果 CoreMedia 对特定四字符标签（FourCC）的黑名单机制。
   * **操作：** 遍历至 moov -> trak -> mdia -> minf -> stbl -> stsd (SampleEntryBox)。
   * **HEVC 替换：** 检测到 hev1，原地覆写为苹果认可的 hvc1 (Hex: 0x68 0x76 0x63 0x31)。
   * **杜比视界替换：** 检测到 dvhe，原地覆写为 dvh1，以激活 iPhone XDR 屏幕的原生杜比流水线。
   * **全景声替换：** 检测到 mp4a 且内部含 Dolby Atmos 元数据时，覆写为 ec-3。
  ### 3. 品牌防伪升级：兼容 CMAF 规范
   * **目标：** 阻止解码器进入旧版 MP4 验证分支。
   * **操作：** 定位文件头部的 ftyp (File Type Box)。将其 major_brand 和 compatible_brands 数组中的 iso5 等陈旧标识，强行覆盖增补为苹果推崇的 cmaf、hlsf (HLS Fragment) 与 iso6。
  ### 4. 数据严格保留：不可触碰的红线
   * **操作：** 严禁在上述过程中误伤 stsd 内的 colr (Color Box) 等其他所有 Box。colr 是触发 iOS 屏幕 EDR HDR10 (PQ) 高亮映射的唯一凭证，误删将导致 HDR 视频褪色发灰。
  ## 五、 模块开发规范与接口契约 (Implementation Boundaries)
  请后续开发 Agent 严格遵循以下跨语言调用边界实现代码：
  ### 模块 1：Rust 核心逻辑 (crates/ibili_core)
  无需引入重型 MP4 解析库，使用轻量的 nom 或 mp4parse 实现极速状态机。
  ```rust
  // crates/ibili_core/src/media/fmp4_patcher.rs
  /// 执行 init.mp4 的外科手术修补
  /// 包含：切除 edts 并修正 size，替换 hev1/dvhe，覆写 ftyp 品牌。
  pub fn patch_fmp4_init_segment(input: &[u8]) -> Result<Vec<u8>, ProtocolCoreError> {
      // 逻辑实现...
  }
  
  ```
  ### 模块 2：Rust FFI 边界 (crates/ibili_ffi)
  遵循内存所有权转移原则，暴露 C 接口，并提供成对的释放函数。
  ```rust
  // crates/ibili_ffi/src/exports/media.rs
  #[no_mangle]
  pub unsafe extern "C" fn ibili_patch_init_segment(
      in_data: *const u8,
      in_len: usize,
      out_data: *mut *mut u8,
      out_len: *mut usize,
  ) -> IbiliCoreResult {
      // 桥接 core 层，转移 Vec<u8> 所有权至 out_data
  }
  
  #[no_mangle]
  pub unsafe extern "C" fn ibili_free_patched_data(ptr: *mut u8, len: usize) {
      // 重建 Vec<u8>，利用 Rust 作用域自动 Drop 释放内存
  }
  
  ```
  ### 模块 3：Swift 代理拦截层 (ProtocolCoreBridge & LocalHLSProxy)
  在 LocalHLSProxy 收到上游返回数据后，同步调用修补逻辑，失败则安全退化。
  ```swift
  // IbiliApp/Sources/Bridge/Media/FMP4Patcher.swift
  func patchInitSegment(data: Data) -> Data {
      return data.withUnsafeBytes { rawBuffer in
          var outPtr: UnsafeMutablePointer<UInt8>? = nil
          var outLen: Int = 0
          
          let result = ibili_patch_init_segment(
              rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
              rawBuffer.count,
              &outPtr,
              &outLen
          )
