# Rust Core and Swift Bridge Interface Design

## 1. Purpose

This document defines the interface contract between the Rust protocol core and the native Swift iOS application.

This is the implementation-oriented follow-up to:

- `./ios-native-development-guide.md`
- `./ios-workspace-architecture.md`
- `./upstream-sync-implementation.md`

The goal is to make the unstable Bilibili-facing protocol layer live behind a stable, testable, Swift-friendly interface.

## 2. Decision

This project should use Rust as the default core library language.

Reasoning:

- better control over FFI boundaries
- better control over memory ownership and lifetime rules
- better binary packaging story for iOS static libraries and XCFrameworks
- easier to keep protocol logic independent from UI code
- safer long-term maintenance for protobuf, header construction, signing, and request routing logic

Go remains a fallback option for a future alternative implementation, but this document standardizes the Rust path so the iOS app can move forward without ambiguity.

## 3. Core Design Rule

The Swift app must never call raw protocol primitives directly.

The Rust core must not expose low-level helpers such as:

- `wbi_sign(params)`
- `app_sign(params)`
- `build_grpc_headers(access_key)`
- `send_rest_request(url, params, headers)`

as its primary app-facing API.

Instead, the public interface must be organized around stable service-level use cases such as:

- session management
- feed loading
- video detail loading
- stream resolution
- danmaku loading
- login flow execution
- upstream manifest and regression operations

This keeps the Swift app decoupled from protocol churn.

## 4. Layering

Recommended integration layers:

```text
SwiftUI Feature
  -> Application UseCase
  -> Infrastructure Repository
  -> ProtocolCoreBridge (Swift)
  -> Rust C ABI / FFI facade
  -> Rust service layer
  -> Rust transport and signer internals
```

Rules:

- SwiftUI features depend on Swift protocols only.
- Swift repositories depend on `ProtocolCoreBridge` only.
- `ProtocolCoreBridge` owns all FFI interaction.
- Rust service layer owns all protocol logic.
- Rust internals own signing, routing, protobuf framing, and transport details.

## 5. Build and Packaging Strategy

Recommended packaging:

- Rust crate compiled to `staticlib`
- packaged into an iOS `XCFramework`
- Swift wrapper distributed as a local Swift package under `ProtocolCoreBridge`

Recommended outputs:

```text
core/rust/
  Cargo.toml
  crates/
    ibili_core/
    ibili_ffi/
  include/
    ibili_ffi.h
  dist/
    IbiliCore.xcframework
```

Recommendation:

- keep protocol code in `ibili_core`
- keep the C ABI facade in `ibili_ffi`
- keep generated or hand-maintained C headers under `include/`

This avoids mixing protocol logic with ABI concerns.

## 6. Rust Crate Layout

Recommended internal crate structure:

```text
crates/ibili_core/
  src/
    account/
    auth/
    signers/
    transport/
    grpc/
    playurl/
    feed/
    danmaku/
    session/
    manifests/
    regression/
    models/
    errors/
    services/
    lib.rs

crates/ibili_ffi/
  src/
    handles/
    runtime/
    strings/
    ffi_models/
    ffi_errors/
    exports/
    lib.rs
```

Responsibility split:

- `ibili_core`: pure Rust domain and protocol logic
- `ibili_ffi`: FFI-safe handles, exported symbols, memory ownership helpers, runtime entry points

## 7. FFI Strategy

Recommended FFI strategy:

- expose a thin C ABI
- keep exported function count small
- use opaque handles for stateful objects
- use JSON or compact FFI DTOs only at stable boundaries
- keep transport internals private to Rust

Do not expose Rust-specific types directly.

Do not expose protobuf message internals to Swift.

Do not expose low-level transport handles unless absolutely required.

## 8. Public ABI Shape

The ABI should revolve around three kinds of exported items:

1. bootstrap functions
2. opaque client/session handles
3. request-response service functions

### 8.1 Opaque Handles

Recommended handles:

- `IbiliCoreHandle`
- `IbiliSessionHandle`
- `IbiliRequestContextHandle`

Opaque handles let Swift hold long-lived state without knowing Rust internals.

### 8.2 Value Passing Rule

Use this rule for boundary payloads:

- small scalars pass as primitive C types
- stable structured input passes as JSON string or FFI DTO struct
- structured output returns as JSON string or explicit FFI result struct

Recommended default for this project:

- use JSON at the outer service boundary for rapid evolution
- use typed Swift DTOs after decoding inside `ProtocolCoreBridge`

This keeps the ABI stable while the Rust internals evolve.

## 9. Public Service Surface

The Rust core should expose service-oriented API groups.

### 9.1 Core Bootstrap API

Required functions:

- create core client
- destroy core client
- update runtime config
- attach logger callback if needed later
- query core version and upstream manifest version

Suggested ABI surface:

```c
IbiliCoreResult ibili_core_create(const char *config_json, IbiliCoreHandle **out_handle);
void ibili_core_destroy(IbiliCoreHandle *handle);
IbiliCoreResult ibili_core_update_config(IbiliCoreHandle *handle, const char *config_json);
const char *ibili_core_version(void);
```

### 9.2 Session API

Responsibilities:

- load persisted session
- import cookie/access token state
- export session snapshot
- clear session
- query login state
- select active account

Suggested Swift-facing operations:

- `loadSession()`
- `saveSession(_:)`
- `clearSession()`
- `currentSession()`
- `switchAccount(id:)`

Suggested ABI direction:

```c
IbiliCoreResult ibili_session_import(IbiliCoreHandle *handle, const char *session_json);
IbiliCoreResult ibili_session_export(IbiliCoreHandle *handle, char **out_json);
IbiliCoreResult ibili_session_clear(IbiliCoreHandle *handle);
IbiliCoreResult ibili_session_status(IbiliCoreHandle *handle, char **out_json);
```

### 9.3 Feed API

Responsibilities:

- load home recommendations
- load paginated feed segments
- support policy differences between web WBI and app routes

Swift-facing operations:

- `fetchHomeFeed(request:)`
- `fetchNextFeedPage(cursor:)`

Suggested Rust request model fields:

- page size
- freshness index or cursor
- login context
- client policy hint if needed

### 9.4 Video API

Responsibilities:

- load video detail
- load related content
- resolve playurl candidates
- resolve episode or season-related playable streams

Swift-facing operations:

- `fetchVideoDetail(id:)`
- `fetchPlayableStreams(request:)`
- `fetchRelatedVideos(id:)`

Important rule:

- the Rust core returns stream candidates and metadata
- the native player module chooses how to play them using Apple frameworks

### 9.5 Danmaku API

Responsibilities:

- load danmaku segment data
- expose danmaku timing and segment metadata

Swift-facing operations:

- `fetchDanmakuSegment(cid:segmentIndex:)`
- `fetchDanmakuConfig(cid:)`

### 9.6 Auth API

Responsibilities:

- TV QR login
- password login
- SMS login
- safe center risk flow
- OAuth code exchange

Swift-facing operations should remain step-oriented rather than one giant login method.

Recommended groups:

- `requestTvQrCode()`
- `pollTvQrCode(authCode:)`
- `loginByPassword(request:)`
- `sendSmsCode(request:)`
- `loginBySms(request:)`
- `safeCenterPrepare(tmpCode:)`
- `safeCenterSendCode(request:)`
- `safeCenterVerify(request:)`
- `exchangeOauthCode(code:)`

This preserves the branching auth model seen in upstream PiliPlus.

### 9.7 Upstream Sync API

The Rust core does not need to own git fetch operations, but it should expose reusable protocol-level helpers for tooling.

Recommended operations:

- generate manifest fingerprint for local implementation
- run protocol regression suites against configured environments

These can later support desktop tooling, CI, or test harnesses.

## 10. Request and Response Modeling

Recommended boundary pattern:

- Swift defines app-facing DTOs
- Swift bridge serializes them to JSON
- Rust parses into internal typed structs
- Rust executes service logic
- Rust serializes stable response DTOs to JSON
- Swift bridge maps JSON to native Swift models

This should be the default for service boundaries.

### 10.1 Why JSON at the ABI Boundary

Reasoning:

- easier forward-compatible evolution of DTOs
- easier to debug while the core is still moving
- fewer C struct migration problems
- simpler Swift wrapper implementation initially

This is not an excuse to be loosely typed inside Rust. Internally, Rust should remain strongly typed.

## 11. Error Model

The error model must be explicit and stable.

Recommended layers:

1. Rust internal error taxonomy
2. FFI-safe error envelope
3. Swift bridge typed error mapping

### 11.1 Rust Internal Error Categories

Suggested categories:

- `ConfigError`
- `SessionError`
- `AuthError`
- `RiskControlError`
- `SigningError`
- `TransportError`
- `DecodeError`
- `GrpcError`
- `ProtocolChangedError`
- `RateLimitError`
- `CancelledError`
- `InternalError`

### 11.2 FFI Error Envelope

Recommended envelope:

```json
{
  "kind": "AuthError",
  "code": "safe_center_required",
  "message": "safe center verification required",
  "retryable": false,
  "details": {
    "tmp_code": "..."
  }
}
```

### 11.3 Swift Mapping

Recommended Swift error enum:

```swift
enum ProtocolCoreError: Error {
    case config(CoreErrorEnvelope)
    case session(CoreErrorEnvelope)
    case auth(CoreErrorEnvelope)
    case riskControl(CoreErrorEnvelope)
    case transport(CoreErrorEnvelope)
    case decode(CoreErrorEnvelope)
    case grpc(CoreErrorEnvelope)
    case protocolChanged(CoreErrorEnvelope)
    case internalFailure(CoreErrorEnvelope)
}
```

The UI should never need to interpret raw Rust strings.

## 12. Memory Ownership Rules

Memory bugs at the bridge are unacceptable.

Recommended rules:

- Swift never frees Rust allocations manually except through explicit exported free functions
- every Rust string returned across FFI must have one corresponding Rust free function
- every opaque handle must have one destroy function
- no borrowed pointers should survive beyond the FFI call boundary

Suggested required exports:

```c
void ibili_string_free(char *ptr);
void ibili_error_free(IbiliError *ptr);
void ibili_core_destroy(IbiliCoreHandle *handle);
```

## 13. Concurrency Model

The Rust core should own its own async runtime boundary, but the Swift app should experience a clean `async/await` API.

Recommended model:

- Rust uses `tokio` or a similarly mature async runtime internally
- FFI exports remain synchronous from the C ABI point of view for the first version
- expensive work executes on Rust-managed runtime threads
- Swift bridge wraps blocking FFI calls on background executors and surfaces them as `async`

This avoids leaking Rust runtime complexity into Swift too early.

### 13.1 Future Evolution

If needed later:

- add callback-based or task-handle-based async FFI
- add streaming events for progress-heavy flows

But version 1 should prefer simplicity over clever async cross-language machinery.

## 14. Swift Bridge Design

The `ProtocolCoreBridge` Swift package should be the only consumer of the C ABI.

Recommended module structure:

```text
ProtocolCoreBridge/
  Sources/
    FFI/
      IbiliFFI.swift
      IbiliFFIHelpers.swift
    Models/
      Requests/
      Responses/
      Errors/
    Clients/
      CoreClient.swift
      SessionClient.swift
      FeedClient.swift
      VideoClient.swift
      AuthClient.swift
      DanmakuClient.swift
    Mapping/
    Internal/
```

### 14.1 Swift Bridge Responsibilities

- call C ABI safely
- manage pointer lifetime
- encode request DTOs to JSON
- decode response DTOs from JSON
- map error envelopes to typed Swift errors
- expose `async` Swift methods

### 14.2 Swift Bridge Non-Responsibilities

- no endpoint selection logic
- no WBI or AppSign logic
- no grpc metadata generation
- no UI-specific formatting
- no feature-specific orchestration

## 15. Swift Public Client API

Recommended public surface:

```swift
public protocol CoreClientProtocol {
    func updateConfig(_ config: CoreRuntimeConfig) async throws
    func coreVersion() -> String
}

public protocol SessionClientProtocol {
    func importSession(_ snapshot: SessionSnapshot) async throws
    func exportSession() async throws -> SessionSnapshot
    func sessionStatus() async throws -> SessionStatus
    func clearSession() async throws
}

public protocol FeedClientProtocol {
    func fetchHomeFeed(_ request: HomeFeedRequest) async throws -> HomeFeedResponse
}

public protocol VideoClientProtocol {
    func fetchVideoDetail(_ request: VideoDetailRequest) async throws -> VideoDetailResponse
    func fetchPlayableStreams(_ request: PlayableStreamRequest) async throws -> PlayableStreamResponse
}

public protocol AuthClientProtocol {
    func requestTvQrCode() async throws -> TvQrCodeResponse
    func pollTvQrCode(_ request: TvQrPollRequest) async throws -> TvQrPollResponse
    func loginByPassword(_ request: PasswordLoginRequest) async throws -> PasswordLoginResponse
    func sendSmsCode(_ request: SmsCodeRequest) async throws -> SmsCodeResponse
    func loginBySms(_ request: SmsLoginRequest) async throws -> SmsLoginResponse
    func safeCenterPrepare(_ request: SafeCenterPrepareRequest) async throws -> SafeCenterPrepareResponse
    func safeCenterSendCode(_ request: SafeCenterSendCodeRequest) async throws -> SafeCenterSendCodeResponse
    func safeCenterVerify(_ request: SafeCenterVerifyRequest) async throws -> SafeCenterVerifyResponse
    func exchangeOauthCode(_ request: OauthCodeExchangeRequest) async throws -> OauthCodeExchangeResponse
}

public protocol DanmakuClientProtocol {
    func fetchDanmakuSegment(_ request: DanmakuSegmentRequest) async throws -> DanmakuSegmentResponse
}
```

This is the surface repositories should consume.

## 16. Configuration Model

The Rust core should accept one runtime config object at bootstrap and allow updates for safe fields.

Suggested config areas:

- base transport timeouts
- proxy settings
- user agent policy
- debug logging enablement
- feature flags for experimental protocol branches
- cache settings
- upstream compatibility mode

Example Swift-facing config:

```swift
struct CoreRuntimeConfig: Codable, Sendable {
    var requestTimeoutMillis: Int
    var connectTimeoutMillis: Int
    var enableDebugLogging: Bool
    var enableHttp2: Bool
    var proxy: ProxyConfig?
    var compatibilityMode: CompatibilityMode
}
```

## 17. Observability

The bridge must support enough diagnostics to debug upstream breakage.

Recommended capability:

- request correlation ID propagation
- stable error codes
- optional debug event callback in development builds
- manifest version reporting
- regression result output for tooling

Do not leak verbose transport internals into production UI.

## 18. Versioning Policy

Recommended versioning layers:

1. ABI version
2. core semantic version
3. upstream reference SHA

The Swift bridge should be able to query all three.

Suggested exported metadata:

- core semantic version
- ABI version
- upstream snapshot identifier
- manifest schema version

This makes compatibility failures diagnosable.

## 19. Testing Strategy

### 19.1 Rust Core Tests

Test:

- signers
- auth policy router
- endpoint registry behavior
- session import/export
- request formation
- response parsing
- risk-control branching
- grpc framing

### 19.2 FFI Tests

Test:

- string allocation and release
- handle create/destroy
- invalid JSON input behavior
- null pointer handling
- error envelope correctness

### 19.3 Swift Bridge Tests

Test:

- DTO encoding and decoding
- error mapping
- `async` wrapper behavior
- memory cleanup around bridge calls

## 20. First Implementation Sequence

Recommended order:

1. create `ibili_core` and `ibili_ffi`
2. implement config bootstrap and version query
3. implement session import/export/status
4. implement feed and video detail APIs
5. implement playurl resolution API
6. implement auth flow APIs
7. build `ProtocolCoreBridge` Swift package
8. integrate repositories in `Infrastructure`
9. add regression and manifest helpers

This sequence gets the app usable early while preserving the intended architecture.

## 21. Non-Negotiable Rules

- Rust owns all unstable protocol behavior.
- Swift owns app composition and native UX.
- The public core interface is service-oriented, not signer-oriented.
- FFI must stay narrow and explicit.
- `ProtocolCoreBridge` is the only Swift package that touches the C ABI.
- Feature modules never know how signing or routing works.
- Native playback stays outside the Rust core.

If this contract is maintained, the protocol core can evolve aggressively while the iOS app remains stable, native, and maintainable.
