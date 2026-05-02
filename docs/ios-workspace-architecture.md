# iOS Workspace Architecture

## 1. Purpose

This document turns the high-level iOS native architecture guide into a concrete workspace and target layout.

Goals:

- keep protocol logic isolated from the UI
- maximize native iOS component usage
- support iOS 26 glass-style visuals with a centralized fallback path
- keep feature code small, testable, and reusable
- make the codebase safe to evolve as protocol behavior changes

This document should be read together with:

- `./ios-native-development-guide.md`
- `./upstream-sync-implementation.md`
- `./rust-core-swift-bridge-interface-design.md`

## 2. Workspace Shape

Recommended top-level structure:

```text
Ibili/
  docs/
  upstream-piliplus/
  ios-app/
    Ibili.xcworkspace
    IbiliApp/
    Packages/
      DesignSystem/
      SharedUI/
      AppFoundation/
      Application/
      Infrastructure/
      ProtocolCoreBridge/
      FeatureHome/
      FeatureVideo/
      FeaturePlayer/
      FeatureDanmaku/
      FeatureSearch/
      FeatureAuth/
      FeatureProfile/
      FeatureDynamic/
      FeatureSettings/
  core/
    rust/ or go/
  tools/
    upstream-sync/
    regression/
```

Recommended approach:

- keep the iOS app in its own `ios-app/` directory
- keep the cross-platform protocol core in `core/`
- keep upstream tooling in `tools/`
- keep feature code inside Swift packages rather than inside one large app target

## 3. Targets and Packages

### 3.1 App Targets

Recommended Xcode targets:

1. `IbiliApp`
2. `IbiliAppTests`
3. `IbiliAppUITests`

Optional later targets:

1. `IbiliShareExtension`
2. `IbiliWidgetExtension`
3. `IbiliNotificationExtension`

The app target should stay thin. It should only own:

- app entry
- dependency graph composition
- environment bootstrap
- app scene routing
- system capability registration

### 3.2 Swift Package Modules

Recommended package ownership:

1. `DesignSystem`
2. `SharedUI`
3. `AppFoundation`
4. `Application`
5. `Infrastructure`
6. `ProtocolCoreBridge`
7. `FeatureHome`
8. `FeatureVideo`
9. `FeaturePlayer`
10. `FeatureDanmaku`
11. `FeatureSearch`
12. `FeatureAuth`
13. `FeatureProfile`
14. `FeatureDynamic`
15. `FeatureSettings`

## 4. Dependency Rules

Dependency direction must remain one-way.

Allowed direction:

```text
Feature* -> Application -> Infrastructure -> ProtocolCoreBridge -> Core Library
Feature* -> SharedUI -> DesignSystem
Feature* -> AppFoundation
Infrastructure -> AppFoundation
SharedUI -> DesignSystem
App target -> all packages
```

Forbidden direction:

- `DesignSystem` must not depend on any feature module.
- `SharedUI` must not import `Infrastructure`.
- `Feature*` modules must not call FFI directly.
- `Application` must not depend on SwiftUI views.
- `ProtocolCoreBridge` must not know about screens or view models.

## 5. Module Responsibilities

### 5.1 DesignSystem

Responsibilities:

- semantic colors
- typography tokens
- radius tokens
- spacing tokens
- elevation and shadow tokens
- glass and fallback materials
- motion tokens
- icon sizing rules
- toolbar and tab chrome styles
- reusable control themes

Suggested folders:

```text
Sources/
  Tokens/
  Materials/
  Controls/
  Layout/
  Motion/
  Accessibility/
```

### 5.2 SharedUI

Responsibilities:

- reusable UI blocks built on `DesignSystem`
- loading, empty, and error states
- reusable cards, rows, badges, pills, avatars, counters
- common pull-to-refresh and paged list containers
- modal and sheet wrappers

Typical examples:

- `AsyncStateView`
- `VideoCard`
- `AuthorRow`
- `StatBadge`
- `GlassPanel`
- `SectionHeader`
- `PagedFeedContainer`

### 5.3 AppFoundation

Responsibilities:

- app-wide primitives and protocols
- environment configuration
- logging interfaces
- feature flags
- error types
- scheduling abstractions
- persistence keys
- system service protocols

Examples:

- `AppEnvironment`
- `Logger`
- `Clock`
- `AppError`
- `FeatureFlagProvider`
- `SessionState`

### 5.4 ProtocolCoreBridge

Responsibilities:

- wrap the Rust or Go exported API
- convert opaque FFI results into Swift value types
- expose `async` and cancellation-aware calls
- isolate memory management and unsafe code

Rules:

- no SwiftUI imports
- no domain policy beyond bridge adaptation
- all FFI and unsafe pointer handling stays here

Suggested substructure:

```text
Sources/
  FFI/
  Models/
  Mapping/
  BridgeClients/
  Errors/
```

### 5.5 Infrastructure

Responsibilities:

- repository implementations
- persistence adapters
- caching
- image loading integration
- account/session storage
- background sync adapters
- upstream sync adapters

This is where the app decides how Swift repositories call the bridge and local storage.

### 5.6 Application

Responsibilities:

- use cases
- coordinators for cross-feature flows
- aggregation of repository results
- business-level retry policy
- pagination orchestration
- feed prefetch orchestration
- player handoff orchestration

Suggested substructure:

```text
Sources/
  UseCases/
  Coordinators/
  Domain/
  Policies/
  Mappers/
```

### 5.7 Feature Modules

Each feature package should own only its presentation and feature-local composition.

Suggested per-feature structure:

```text
Sources/
  Scene/
  ViewModels/
  Components/
  Routing/
  State/
  Preview/
```

Rules:

- one scene entry per major screen
- one view model per screen or large section
- reusable subviews move to `Components/`
- no raw endpoint strings
- no signing or request building

## 6. Feature Breakdown

### 6.1 FeatureHome

Owns:

- home tab shell
- recommendation feed
- category switching if introduced later
- refresh and feed pagination UI

Should depend on:

- `Application`
- `SharedUI`
- `DesignSystem`
- `AppFoundation`

### 6.2 FeatureVideo

Owns:

- video detail scene
- metadata panels
- comments entry
- related content panels
- selectable qualities and episodes entry points

Must not own the player engine itself.

### 6.3 FeaturePlayer

Owns:

- native player host scene
- overlay controls
- gesture handling
- PiP integration
- quality switching UI
- subtitle and audio route UI
- brightness and volume interaction policy

Recommended internal split:

```text
FeaturePlayer/
  Scene/
  PlayerHost/
  Overlay/
  Controls/
  Gestures/
  State/
  Routing/
```

Player-specific rule:

- render using native media APIs
- keep protocol stream resolution outside this module

### 6.3.1 Playback ADR Note

As of 2026-05-02, the repository has a verified playback constraint for HEVC Main10 HDR variants such as qn125:

- the current live `sidx -> HLS BYTERANGE` proxy path is not the long-term architecture target
- repeated `init.mp4` patching and FFmpeg live remux experiments did not solve `CoreMediaErrorDomain -12927`
- the strategic direction for the AVPlayer path is Apple-compatible HLS/CMAF packaging with segment semantics controlled by a real packager, not by ad-hoc local proxy patching

As of the same date, one remaining Dolby Vision class was also root-caused more precisely:

- some `dvh1.08.xx` samples are Dolby Vision 8.4 with HLG-compatible base layer, not PQ
- these streams must be authored with base `hvc1` in `CODECS`, Dolby Vision in `SUPPLEMENTAL-CODECS`, and `VIDEO-RANGE=HLG`
- inferring HDR range from qn alone is not reliable and must not override parsed init metadata
- diagnostics-browser workspace smoke tests now use a direct file URL so packaged-HLS validation is isolated from localhost delivery behavior

Implication:

- `FeaturePlayer` may continue to host the current engine stack for ordinary streams, but future investment for unsupported HEVC/HDR variants must go into proper packaging, not more proxy-layer hotfixes

### 6.4 FeatureDanmaku

Owns:

- danmaku overlay orchestration
- danmaku settings UI
- danmaku filtering and timing controls

The actual data loading should still come from `Application` use cases and repositories.

### 6.5 FeatureAuth

Owns:

- login method selection UI
- password login UI
- SMS login UI
- TV QR login UI
- risk-control verification UI
- account switching UI

The feature should model the login process as scenes over a state machine rather than one large screen.

## 7. Scene Composition Rules

### 7.1 Maximum File Size Heuristic

Strong recommendation:

- SwiftUI view files should usually remain below 200 to 300 lines
- view model files should usually remain below 250 to 350 lines
- if a file grows past that because of repeated UI blocks, split components immediately

### 7.2 Scene Layers

Recommended scene layering:

1. `Scene`
2. `ScreenState`
3. `ViewModel`
4. `Section Views`
5. `Reusable Components`

Example:

```text
VideoDetailScene
  -> VideoDetailViewModel
  -> VideoDetailState
  -> VideoHeaderSection
  -> VideoActionsSection
  -> RelatedFeedSection
  -> Reusable components from SharedUI
```

### 7.3 State Shape

Each major screen should explicitly model:

- initial loading
- refresh loading
- loaded content
- paginating content
- empty state
- recoverable error
- unrecoverable error

Avoid boolean soup such as multiple unrelated flags with no single source of truth.

## 8. Native iOS 26 Glass Implementation

### 8.1 Centralized Provider

Implement the glass behavior once in the design system.

Recommended abstractions:

- `SurfaceToken`
- `ChromeToken`
- `GlassStyleProviding`
- `ResolvedSurfaceStyle`

Recommended providers:

- `IOS26GlassProvider`
- `FallbackMaterialProvider`

### 8.2 Usage Pattern

Views ask for semantic styling, not platform-specific implementation.

Example policy:

- navigation bar background uses `chromeToken = .navigationBar`
- player floating controls use `surfaceToken = .floatingOverlay`
- tab shell uses `chromeToken = .tabBar`
- cards use `surfaceToken = .card`

The provider resolves the actual iOS 26 glass style or fallback material.

### 8.3 Fallback Policy

For lower iOS versions:

- preserve the same hierarchy and interaction structure
- use tokenized blur and material styling
- do not create a second design language

This means the fallback differs in implementation, not in information architecture.

## 9. Testing Strategy by Layer

### 9.1 DesignSystem Tests

Test:

- token mapping
- glass provider fallback behavior
- accessibility contrast assumptions where possible

### 9.2 Application Tests

Test:

- use case behavior
- retry policy
- pagination policy
- account/session transitions

### 9.3 Infrastructure Tests

Test:

- repository mapping
- persistence behavior
- bridge error handling
- cache invalidation logic

### 9.4 Feature Snapshot and Interaction Tests

Test:

- representative screen states
- loading / empty / error rendering
- player overlay state changes
- auth scene transitions

## 10. Initial Build Order

Recommended order:

1. create workspace and package graph
2. build `DesignSystem`
3. build `AppFoundation`
4. build `ProtocolCoreBridge`
5. build `Infrastructure`
6. build `Application`
7. build `SharedUI`
8. build `FeatureHome`
9. build `FeatureVideo`
10. build `FeaturePlayer`
11. build `FeatureAuth`
12. add remaining features

This order reduces rework because the lower layers stabilize before features multiply.

## 11. Non-Negotiable Rules

- The app target must stay thin.
- Cross-feature reusable UI belongs in `SharedUI`, not random feature folders.
- Styling belongs in `DesignSystem`, not feature code.
- View models call use cases, not repositories directly unless the feature is deliberately trivial.
- Repositories stay in `Infrastructure`.
- All FFI stays in `ProtocolCoreBridge`.
- All protocol behavior stays outside SwiftUI features.
- All glass and fallback behavior is resolved by semantic style providers.

If this structure is respected, the codebase stays maintainable even when the protocol core and UI both evolve quickly.
