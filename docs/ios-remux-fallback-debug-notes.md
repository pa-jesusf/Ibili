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

最新日志显示 AVPlayer 的请求顺序是：

```text
/remux/<token>/master.m3u8
/remux/<token>/video.m3u8
/remux/<token>/init.mp4
```

然后立即失败：

```text
AVPlayerItem 失败 | CoreMediaErrorDomain -12927
```

没有请求 `seg-0.m4s`。

结论：当前拒绝点基本锁定在 remux 输出的 `init.mp4` 初始化信息，而不是 master playlist、media playlist 或首个 media fragment。

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

## 当前最可疑点

`ffprobe-init-trace.txt` 显示 remux 输出的 `init.mp4` 含有 `edts/elst`：

```text
type:'edts' parent:'trak'
type:'elst' parent:'edts'
track[0].edit_count = 2
duration=33 time=-1 rate=1.000000
duration=0 time=528 rate=1.000000
advanced_editlist does not work with fragmented MP4. disabling.
```

这和 AVPlayer 在 `init.mp4` 阶段直接拒绝高度相关。当前第一优先怀疑对象是：FFmpeg HLS fMP4 muxer 生成的 `edts/elst` edit list 与 AVPlayer 对 fragmented MP4 HLS init segment 的要求不兼容。

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

### 3. C wrapper muxer 参数

在 `ios-app/ThirdParty/ffmpeg/wrapper/FFmpegRemux.c` 的 `ibili_remux_hls_live` 中加入了：

```c
av_dict_set(&mux_opts, "movflags", "+frag_keyframe+empty_moov+default_base_moof+negative_cts_offsets", 0);
av_dict_set(&mux_opts, "use_editlist", "0", 0);
```

注意：macOS 上用 FFmpeg CLI 对照测试时，`-use_editlist 0` 对 HLS fMP4 muxer 未必能去掉 `edts/elst`。所以这一步需要在 iOS framework 重编后验证，但不能假设一定有效。

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

### 优先验证

重编 FFmpegRemux 后再跑 qn=125，观察新日志：

```text
remux init.mp4 诊断 | allBoxTypes=...
```

如果 `allBoxTypes` 中仍然有：

```text
edts,elst
```

说明 FFmpeg HLS muxer 参数未能去掉 edit list。

### 方案 A：代理层 patch init.mp4

如果 `edts/elst` 仍存在，优先尝试在 `LocalHLSProxy` 服务 `init.mp4` 前做 box-level patch：

- 删除 `moov/trak/edts`。
- 修正父 box size：`trak`、`moov`。
- 保留 `hvc1/hvcC/colr/pasp/btrt/mvex/trex`。

这是最小侵入方案，不改变长生命周期 FFmpeg pipeline，也不影响 CDN fragment 按需读取。

### 方案 B：不用 FFmpeg HLS muxer，改为自定义 fMP4 输出

如果 patch init 后仍失败，考虑绕开 FFmpeg HLS muxer，改用更可控的 fragmented MP4 输出：

```text
init.mp4 + moof/mdat segments + 自己生成 m3u8
```

这能更精确控制 boxes、timeline、fragment flags，但工程量较大。

### 还需排查

如果去掉 `edts/elst` 后仍在 `init.mp4` 阶段失败，需要继续排查：

- HEVC Main10 HDR PQ 是否被当前设备拒绝。
- `hvcC` profile/compat/level 是否与设备能力不匹配。
- `colr` box：`nclx pri=9 trc=16 matrix=9 full=0` 是否触发拒绝。
- 是否需要保留/移除 HDR metadata box。
- macOS AVFoundation 与 iOS AVFoundation 的行为差异。
