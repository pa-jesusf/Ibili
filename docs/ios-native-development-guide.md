# iOS Native Development Guide

## 1. Goals

This project will use a hybrid architecture:

- Protocol, signing, auth, protobuf, and upstream-compatibility logic live in a cross-platform core library written in Go or Rust.
- iOS UI, navigation, interaction, and playback are implemented with native Swift and SwiftUI.
- Performance-sensitive playback, scrolling, image rendering, and gesture handling should use native Apple frameworks first.
- The project must remain maintainable when Bilibili changes unofficial API behavior, so upstream tracking and regression checks are part of the architecture rather than an afterthought.

The main source of protocol truth is the upstream PiliPlus repository currently mirrored in this workspace under:

- `upstream-piliplus/`

This guide focuses on architecture, development boundaries, and implementation principles for the iOS client.

Companion documents:

- `./ios-workspace-architecture.md`
- `./upstream-sync-implementation.md`
- `./rust-core-swift-bridge-interface-design.md`

## 2. Core Principles

### 2.1 Native First

When building the iOS client, prefer Apple native components and native rendering paths wherever possible.

- Use SwiftUI as the primary UI framework.
- Use UIKit interop only where SwiftUI still has clear gaps.
- Use `AVPlayer`, `AVAudioSession`, `VideoToolbox`, `CoreImage`, `CoreAnimation`, and system media APIs before considering custom rendering stacks.
- Prefer `NavigationStack`, `TabView`, `sheet`, `fullScreenCover`, `searchable`, system context menus, native drag-and-drop, native text selection, and native share sheets.
- Avoid re-implementing controls that iOS already provides unless the product experience clearly requires it.

### 2.2 Business and UI Separation

The UI layer must not directly know about WBI, AppSign, gRPC metadata, protobuf framing, or raw request composition.

- UI layer only consumes typed use cases and view models.
- Feature modules only depend on application-facing interfaces.
- Protocol details live in the core library and Swift infrastructure adapters.
- Design system components do not import feature business logic.

### 2.3 Small, Reusable UI Components

All UI should be broken into reusable parts rather than large screens with embedded logic.

- Screens compose sections.
- Sections compose cards, rows, controls, and overlays.
- Shared styling is driven by tokens and component variants.
- Repeated Bilibili-like presentation patterns should be standardized once in shared UI.

### 2.4 Upstream Compatibility Is a First-Class Requirement

The app must expect upstream API drift.

- Protocol logic is isolated.
- Upstream tracking is automated.
- Regression checks run against protocol-critical flows.
- Breaking upstream changes should surface as reports and failing checks before they reach the app UI.

## 3. Recommended High-Level Architecture

Recommended structure:

1. `Core Protocol Library` (Rust preferred, Go acceptable)
2. `Swift Infrastructure Layer`
3. `Application Layer`
4. `Presentation Layer`
5. `Design System`

### 3.1 Core Protocol Library

This layer owns all unstable Bilibili-facing behavior.

Responsibilities:

- WBI signing
- AppSign signing
- gRPC metadata/header building
- protobuf encode/decode
- request policy routing
- login and risk-control flows
- cookie and access token state handling
- endpoint manifests
- upstream diff fingerprints

Suggested internal modules:

- `account_store`
- `auth_policy`
- `signers`
- `rest_transport`
- `grpc_transport`
- `endpoint_registry`
- `login_flow`
- `playurl_flow`
- `proto_models`
- `upstream_manifest`
- `regression_runner`

Recommendation:

- Prefer Rust if iOS is the primary delivery target and long-term binary stability matters.
- Prefer Go only if the team already has strong Go tooling and wants faster first delivery.

Rust is the more natural choice for this project because FFI boundaries, binary size control, memory ownership, and protobuf/gRPC framing tend to be easier to reason about for a mobile client core.

### 3.2 Swift Infrastructure Layer

This layer adapts the core library into native iOS services.

Responsibilities:

- FFI bridge wrapper
- async Swift API surface
- repository implementations
- request scheduling / cancellation mapping
- local persistence adapters
- logging / diagnostics hooks
- feature-facing service interfaces

This layer should expose Swift-native abstractions such as:

- `VideoRepository`
- `HomeFeedRepository`
- `AuthRepository`
- `DanmakuRepository`
- `AccountSessionRepository`
- `UpstreamSyncRepository`

The rest of the app should not import raw FFI functions.

### 3.3 Application Layer

This layer defines use cases and feature orchestration.

Responsibilities:

- compose repositories
- manage user actions
- convert domain results into UI-friendly state
- handle retry and fallback policy
- coordinate background refresh and prefetch

Suggested use cases:

- `LoadHomeFeedUseCase`
- `LoadVideoDetailUseCase`
- `LoadPlayableStreamsUseCase`
- `RefreshSessionUseCase`
- `LoginByPasswordUseCase`
- `LoginBySmsUseCase`
- `LoginByTvQrUseCase`
- `LoadDanmakuSegmentUseCase`
- `SyncUpstreamManifestUseCase`
- `RunProtocolRegressionUseCase`

### 3.4 Presentation Layer

This layer owns view composition and state rendering only.

Recommended pattern:

- `SwiftUI + MVVM`
- one view model per screen or major section
- coordinator/router objects for navigation and cross-feature transitions

Rules:

- views never build auth params
- views never read cookies directly
- views never know endpoint names
- view models call use cases, not transports
- view models expose immutable render state and user intents

### 3.5 Design System

Create a dedicated design system module early.

Responsibilities:

- color tokens
- typography tokens
- spacing tokens
- glass / blur / material styles
- icon rules
- button variants
- card variants
- toolbar variants
- player overlays
- empty / loading / error states

If the design system is skipped, the app will quickly become hard to maintain because video, dynamic, article, comment, and mine pages all reuse slightly different card and panel patterns.

## 4. iOS Native UI Strategy

### 4.1 Default UI Stack

Use SwiftUI for most views.

Recommended native building blocks:

- `NavigationStack` for navigation
- `TabView` for the main shell
- `ScrollView` and `LazyVStack` for feed layouts
- `List` only where native grouped list behavior is actually desired
- `PhotosPicker` / system pickers where applicable
- system share sheet for link and media exports
- system context menu and swipe actions
- `refreshable` for pull-to-refresh
- system text input, focus, and keyboard management

### 4.2 UIKit Interop Boundaries

Use UIKit only for specific cases such as:

- advanced player host controller behavior
- custom collection layouts if SwiftUI performance becomes a bottleneck
- image viewer or gesture-heavy zoom experiences if profiling shows SwiftUI is insufficient
- system integration points with better UIKit support

UIKit usage should be wrapped in focused adapters, not leaked across feature modules.

### 4.3 Playback Strategy

Playback must remain fully native on iOS.

Recommended order:

1. `AVPlayer` as the primary playback engine
2. `AVFoundation` for stream switching, PiP, audio session, subtitles, and system transport controls
3. `VideoToolbox` only when you need lower-level decode or advanced optimization
4. custom rendering only if measurement proves Apple frameworks cannot satisfy a target scenario

The protocol layer should only return stream candidates, codecs, qualities, and metadata. The player module decides which native playback path to use.

## 5. iOS 26 Liquid Glass Strategy

The app should support iOS 26 glass-style system visuals when available, and use a well-defined fallback on lower versions.

### 5.1 Design Rule

Do not scatter availability checks across the app.

Instead, centralize them in a style provider layer.

Suggested abstraction:

- `GlassStyleProviding`
- `GlassEffectToken`
- `SurfaceStyle`
- `ChromeStyle`

Suggested implementations:

- `IOS26GlassProvider`
- `FallbackMaterialProvider`

### 5.2 Behavior

When iOS 26 APIs are available:

- use the new system glass materials and related container styling
- apply them to navigation chrome, tab chrome, player overlays, floating panels, and cards where appropriate
- keep interactive affordances native and readable

When the app runs below iOS 26:

- fall back to a tokenized material system built on stable blur / material primitives
- preserve spacing, contrast, hierarchy, and interaction behavior
- avoid making the fallback look like a different product

### 5.3 Implementation Requirement

All feature code should request style tokens, not concrete platform APIs. This keeps future glass changes localized.

Example direction:

- feature asks for `surfaceStyle = .floatingPanel`
- design system resolves to iOS 26 glass if available
- otherwise resolves to fallback material

This is the correct maintainability boundary.

## 6. Protocol and Data Flow Reference from PiliPlus

The upstream PiliPlus repository already reveals the routing model that your core library should reproduce.

### 6.1 Request Entry

The unified request entry is in `upstream-piliplus/lib/http/init.dart`.

Key observations:

- one global HTTP client is initialized
- an account-aware interceptor is installed
- cookie loading and account refresh happen centrally

### 6.2 Auth Routing

The key control point is `upstream-piliplus/lib/utils/accounts/account_manager/account_mgr.dart`.

Routing behavior:

- web REST: attach account headers, referer, and cookies
- app REST: inject `access_key`, then apply AppSign
- app bytes request: treat as gRPC and inject gRPC metadata headers
- login endpoints: often force anonymous routing first

This is the architecture you should preserve. Do not let each endpoint choose auth independently.

### 6.3 Signers

Upstream signer sources:

- WBI: `upstream-piliplus/lib/utils/wbi_sign.dart`
- AppSign: `upstream-piliplus/lib/utils/app_sign.dart`
- gRPC headers: `upstream-piliplus/lib/utils/accounts/grpc_headers.dart`

These must become independent modules in your core library.

### 6.4 Account Model

Upstream account state is represented in `upstream-piliplus/lib/utils/accounts/account.dart`.

Important fields:

- cookie jar
- `accessKey`
- `refresh`
- `csrf`
- normal request headers
- gRPC headers

Your own core library should model the same state, but with explicit serialization and migration rules.

### 6.5 Login Flows

Upstream login flows live mainly in `upstream-piliplus/lib/http/login.dart`.

Important supported paths:

- TV QR login
- password login
- SMS login
- safe-center risk-control SMS verification
- OAuth code to access token exchange

This means your core library should expose multiple login pipelines, not a single `login()` function.

### 6.6 Video / Play URL Flows

Representative upstream logic lives in `upstream-piliplus/lib/http/video.dart`.

Important paths:

- web recommendation via WBI
- app recommendation with Android HD headers
- web playurl via WBI-signed params
- TV/app playurl via `access_key + AppSign`

This should directly inform your `PlayurlService` design.

## 7. Recommended Module Layout for the iOS App

Suggested package / target split:

1. `AppShell`
2. `DesignSystem`
3. `SharedUI`
4. `AppFoundation`
5. `Infrastructure`
6. `Application`
7. `FeatureHome`
8. `FeatureVideo`
9. `FeaturePlayer`
10. `FeatureDanmaku`
11. `FeatureSearch`
12. `FeatureAuth`
13. `FeatureProfile`
14. `FeatureDynamic`
15. `ProtocolCoreBridge`

Suggested ownership:

- `DesignSystem`: tokens, surfaces, reusable controls
- `SharedUI`: shared views composed from tokens
- `Infrastructure`: repository implementations, persistence, bridge wrappers
- `Application`: use cases and coordinators
- `Feature*`: screen-specific presentation and scene composition
- `ProtocolCoreBridge`: Swift wrapper around Rust or Go exports

## 8. UI Component Granularity Rules

To keep the iOS codebase maintainable, UI granularity should be enforced from the start.

### 8.1 Screen Composition Rule

Each screen should be composed in four levels at most:

1. Scene container
2. Section container
3. Reusable content block
4. Primitive control

Example for a video detail page:

- `VideoDetailScene`
- `VideoHeaderSection`
- `VideoMetaRow`
- `StatBadge`

Do not build 800-line scene files with inline row logic.

### 8.2 Styling Rule

No feature module may define its own ad hoc spacing or color palette unless it is extending a design token.

### 8.3 State Rule

Each screen should explicitly model:

- loading
- content
- empty
- error
- partial refresh

This prevents state bugs from leaking into view code.

## 9. Automatic Upstream Update Mechanism

The upstream repository should act as a protocol reference, not as code to be blindly copied.

### 9.1 Watch Targets

The watcher should primarily track changes in these files or areas:

- `upstream-piliplus/lib/http/api.dart`
- `upstream-piliplus/lib/http/login.dart`
- `upstream-piliplus/lib/http/video.dart`
- `upstream-piliplus/lib/utils/accounts/account_manager/account_mgr.dart`
- `upstream-piliplus/lib/utils/accounts/api_type.dart`
- `upstream-piliplus/lib/utils/app_sign.dart`
- `upstream-piliplus/lib/utils/wbi_sign.dart`
- `upstream-piliplus/lib/utils/accounts/grpc_headers.dart`
- `upstream-piliplus/lib/grpc/url.dart`
- `upstream-piliplus/lib/grpc/**/*.pb*.dart`
- `upstream-piliplus/lib/common/constants.dart`

### 9.2 Generated Manifest Strategy

Build a small extractor tool that generates normalized manifests from upstream code.

Recommended manifests:

- `endpoint_manifest.json`
- `auth_policy_manifest.json`
- `signing_manifest.json`
- `grpc_manifest.json`
- `proto_fingerprint_manifest.json`

The goal is to diff behavior, not raw source files.

### 9.3 Change Classification

Each upstream change should be classified into categories such as:

- endpoint added or removed
- auth policy changed
- WBI bootstrap changed
- AppSign input changed
- gRPC metadata changed
- login risk path changed
- playurl parameter changed
- protobuf schema changed

### 9.4 Regression Checks

The protocol regression suite should cover at least:

- home recommendation fetch
- video detail fetch
- WBI playurl fetch
- TV/app playurl fetch
- gRPC view or dm fetch
- password login happy path
- SMS login path
- risk-control SMS verification path
- TV QR login path

### 9.5 Automation Flow

Recommended automation pipeline:

1. scheduled job fetches latest upstream commit
2. extractor regenerates manifests
3. diff classifier produces a report
4. protocol regression suite runs against your core library
5. if behavior changed, open a review task or PR automatically

This gives you early warning without forcing unsafe auto-merges.

## 10. Development Order

Recommended implementation order:

1. define module boundaries and naming conventions
2. implement core account model and signer interfaces
3. implement AppSign, WBI, and gRPC metadata builders
4. implement endpoint policy router
5. implement playurl and login flows
6. implement Swift bridge and repository interfaces
7. build the design system and app shell
8. build home, video detail, player, and auth features
9. add upstream manifest extractor and regression suite
10. optimize hot paths based on profiling

## 11. Non-Negotiable Engineering Rules

- No view may call raw FFI functions directly.
- No feature may hardcode endpoint strings.
- No feature may hand-build signed params.
- No screen may own both complex business logic and layout logic in one file.
- All glass / material styling must go through the design system.
- All platform availability checks for glass styling must be centralized.
- Playback decisions belong to the player module, not feed cells.
- Upstream sync results must be reviewable and reproducible.

## 12. Immediate Next Deliverables

After this document, the recommended next artifacts were:

1. a concrete module tree for the iOS workspace
2. a Swift-side architecture skeleton
3. a Rust or Go core library interface definition
4. an upstream manifest extractor design doc
5. a protocol regression test plan

Current status:

- item 1 is now expanded in `./ios-workspace-architecture.md`
- item 3 is now expanded in `./rust-core-swift-bridge-interface-design.md`
- part of item 4 and item 5 is now expanded in `./upstream-sync-implementation.md`

If these are followed, the project will stay native on iOS, preserve performance-sensitive paths, remain maintainable, and stay resilient against upstream API drift.
