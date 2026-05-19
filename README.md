# Ibili

Native iOS Bilibili client. Architecture: **Rust core** (`core/rust`) + **Swift/SwiftUI app** (`ios-app`).

See [`docs/`](docs/) for full architecture and protocol references.

## Prerequisites

```bash
brew install xcodegen          # required
brew install xcpretty          # optional: prettier xcodebuild logs
rustup target add aarch64-apple-ios
```

Xcode 16+ recommended. iOS deployment target: 16.0.

## Local secrets

Some optional integrations are injected through build settings instead of being
committed to the repository. Copy the example file and fill in your local values:

```bash
cp .env.example .env.local
```

`.env.local` is ignored by git. It is read by `tools/build_unsigned_ipa.sh`.

Supported keys:

```bash
DANDANPLAY_APP_ID=
DANDANPLAY_APP_SECRET=
DANDANPLAY_CALLBACK_URL=
```

## Build an unsigned IPA

```bash
./tools/build_unsigned_ipa.sh
# → dist/Ibili-unsigned.ipa
```

The script runs:
1. `cargo build` for `aarch64-apple-ios` → `ios-app/Frameworks/IbiliCore.xcframework`
2. `xcodegen generate` → `ios-app/Ibili.xcodeproj`
3. `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO`
4. Manual `Payload/Ibili.app` repackage → `dist/Ibili-unsigned.ipa`

To sideload, sign with your own developer profile (e.g. `codesign --force --sign "<id>"`) or a tool such as AltStore.

## Just rebuild the Rust core

```bash
./tools/build_rust_xcframework.sh             # device only
./tools/build_rust_xcframework.sh --with-sim  # device + simulator
```

## Open in Xcode

```bash
cd ios-app && xcodegen generate && open Ibili.xcodeproj
```

## Feature snapshot

| Feature | Status |
| --- | --- |
| TV QR login (扫码登录) | ✅ |
| Logout | ✅ |
| Home recommendation feed | ✅ |
| Search / history / comments | ✅ |
| Native AVPlayer playback | ✅ |
| DASH / HLS proxy playback | ✅ |
| Danmaku / CC subtitles / timeline | ✅ |
| Bangumi anime tracking | ✅ |
| Anime source rules and WebView sniffing | ✅ |
| Dandanplay anime danmaku | ✅ when credentials are configured |
| Built-in Bilibili anime source | ✅ |
| WBI signing | ✅ implemented (not yet used; reserved for web endpoints) |

## Source layout

```
core/rust/
  Cargo.toml                       (workspace)
  crates/ibili_core/               (signers, http, auth, feed, video)
  crates/ibili_ffi/                (C ABI: opaque handle + JSON dispatch)
    include/ibili.h                (umbrella header)
    include/module.modulemap

ios-app/
  project.yml                      (XcodeGen)
  IbiliApp/Sources/
    App/                           (entry, RootView, AppSession)
    Bridge/                        (CoreClient, CoreDTOs, SessionStore)
    DesignSystem/                  (Theme, GlassSurface, RemoteImage, QR)
    Features/Anime/                (Bangumi tracking, source rules, anime player)
    Features/Auth/                 (LoginView + ViewModel)
    Features/Home/                 (HomeView + ViewModel + VideoCardView)
    Features/Player/               (PlayerView + ViewModel)
    Features/Settings/             (settings and source management)
  IbiliApp/Info.plist
  Frameworks/IbiliCore.xcframework (generated)

tools/
  build_rust_xcframework.sh
  build_unsigned_ipa.sh
```

## Notes

- The IPA is unsigned. iOS will not install it without re-signing.
- Bilibili `durl` URLs require `Referer` and a Bilibili `User-Agent`; the player attaches these via `AVURLAsset` HTTP header options.
- TV QR login uses `appkey=4409e2ce8ffd12b8`. After confirmation the resulting `access_token` is reused as `access_key` for app endpoints (`feed/index`, `playurl`).
- `Cargo.lock` is committed for reproducible builds.
