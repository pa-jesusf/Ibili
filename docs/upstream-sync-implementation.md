# Upstream Sync and Protocol Regression Implementation

## 1. Purpose

This document describes how to track protocol-relevant changes in the upstream PiliPlus repository and turn them into actionable maintenance work.

The goal is not to mirror upstream source code mechanically.

The goal is to:

- detect protocol behavior changes early
- normalize upstream behavior into manifests
- classify the risk of changes
- run regression checks against the local core library
- open explicit maintenance tasks when drift is detected

This document should be read together with:

- `./ios-native-development-guide.md`
- `./ios-workspace-architecture.md`
- `./rust-core-swift-bridge-interface-design.md`

## 2. Source of Truth

The upstream protocol reference currently lives in this workspace at:

- `upstream-piliplus/`

The local implementation under maintenance is expected to live in:

- `core/`
- `ios-app/`

The sync system should treat upstream as a behavioral reference, not as a direct code dependency.

## 3. Scope of Watched Changes

The sync system should primarily track these upstream files and areas:

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

These files define most of the behavior that can break the local core library.

## 4. System Components

Recommended sync system components:

1. `UpstreamFetcher`
2. `ReferenceExtractor`
3. `ManifestStore`
4. `DiffClassifier`
5. `RegressionRunner`
6. `ReportGenerator`
7. `TaskEmitter`

## 5. Component Responsibilities

### 5.1 UpstreamFetcher

Responsibilities:

- fetch the latest upstream commit
- record latest tag and release metadata
- store commit SHA history for local comparisons
- optionally keep a shallow clone updated

Recommended outputs:

- `latest_sha`
- `latest_tag`
- `latest_release`
- `changed_files`

Recommended trigger cadence:

- scheduled every 6 hours for development branches
- daily at minimum if resources are constrained
- manual trigger before releases

### 5.2 ReferenceExtractor

Responsibilities:

- parse watched files
- extract endpoint and auth behavior into normalized manifests
- avoid storing raw upstream source as the main artifact

Preferred extraction strategy:

- phase 1: regex plus structured parser helpers for narrow known patterns
- phase 2: move to a more formal parser when the extractor surface grows

The extractor should be deterministic and idempotent.

### 5.3 ManifestStore

Responsibilities:

- store current manifests
- store previous manifests
- store metadata about which upstream SHA produced them
- make diffs reproducible

Recommended storage location:

```text
tools/upstream-sync/artifacts/
  manifests/
  diffs/
  reports/
```

### 5.4 DiffClassifier

Responsibilities:

- compare old and new manifests
- tag changes by risk class
- determine which regression suites must run
- decide whether a human review task is required

### 5.5 RegressionRunner

Responsibilities:

- run protocol-critical checks against the local core library
- record pass or fail output
- attach output to the change report

### 5.6 ReportGenerator

Responsibilities:

- summarize the upstream change
- explain which protocol surface moved
- list impacted local modules
- attach regression results

### 5.7 TaskEmitter

Responsibilities:

- open a PR, issue, or internal task when required
- assign labels by risk type
- include direct evidence and recommended owner areas

## 6. Manifest Design

Recommended manifests:

1. `endpoint_manifest.json`
2. `auth_policy_manifest.json`
3. `signing_manifest.json`
4. `grpc_manifest.json`
5. `proto_fingerprint_manifest.json`
6. `login_flow_manifest.json`
7. `playurl_manifest.json`

### 6.1 Endpoint Manifest

Purpose:

- track endpoint names, domains, and routing categories

Suggested fields:

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

Purpose:

- track which route family uses which auth behavior

Suggested fields:

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

Purpose:

- track AppSign and WBI input behavior

Suggested fields:

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

Purpose:

- track grpc routes and binary metadata structure

Suggested fields:

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

Purpose:

- detect protobuf surface changes without storing full generated source diffs as the primary signal

Suggested fields:

- service name
- route name
- message name
- field count
- field numbers
- field names
- field wire types

### 6.6 Login Flow Manifest

Purpose:

- track branching points in auth and risk-control flows

Suggested entries:

- TV QR auth code request
- TV QR poll
- password login
- SMS login
- safe center pre-captcha
- safe center SMS send
- safe center SMS verify
- OAuth code to access token exchange

### 6.7 Playurl Manifest

Purpose:

- detect changes in stream acquisition behavior

Suggested fields:

- route family
- required params
- optional params
- flags such as `fourk`, `fnval`, `try_look`
- whether route is WBI or AppSign based

## 7. Change Classification

The diff classifier should emit one or more of the following labels:

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

Recommended risk levels:

1. `low`
2. `medium`
3. `high`
4. `critical`

Examples:

- `endpoint_added` is usually `low` or `medium`
- `proto_schema_changed` is usually `high`
- `app_sign_behavior_changed` is `critical`
- `risk_control_flow_changed` is `high` or `critical`

## 8. Regression Suite Design

The regression suite should validate the local protocol core, not the upstream Dart app.

Recommended minimum suites:

### 8.1 Feed Suite

Checks:

- home recommendation fetch using WBI path
- app recommendation fetch using app headers if supported locally

### 8.2 Video Suite

Checks:

- video detail fetch
- web playurl fetch
- TV or app playurl fetch
- stream metadata parse

### 8.3 gRPC Suite

Checks:

- view fetch
- danmaku segment fetch
- reply or dynamic grpc path if supported locally

### 8.4 Auth Suite

Checks:

- password login request formation
- SMS login request formation
- safe center request formation
- TV QR login flow request formation
- OAuth access token exchange request formation

### 8.5 Manifest Consistency Suite

Checks:

- every watched upstream change maps to a manifest diff
- every manifest diff maps to a classifier label
- required regression suites were actually selected

## 9. Execution Flow

Recommended pipeline:

1. fetch latest upstream commit
2. detect whether watched files changed
3. extract manifests from the new upstream snapshot
4. compare manifests against the previous snapshot
5. classify the diffs
6. select the required regression suites
7. run regressions against the local core library
8. generate a human-readable report
9. create a task or PR if the change is medium risk or above

If watched files did not change, the pipeline can skip the expensive stages.

## 10. Report Format

Each generated report should include:

- upstream commit SHA
- upstream tag if available
- changed watched files
- manifest diff summary
- classifier labels
- risk level
- regression suites run
- regression results
- impacted local modules
- suggested owner area

Recommended output files:

```text
tools/upstream-sync/artifacts/reports/
  2026-04-28T120000Z-main-<sha>.md
```

## 11. Suggested Implementation Layout

Recommended tool layout:

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

Recommended regression layout:

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

## 12. Ownership Mapping

Recommended local ownership mapping:

- auth and signing changes -> `core` owner
- grpc metadata and protobuf changes -> `core` owner
- repository mapping changes -> `Infrastructure` owner
- feature-level fallout -> relevant `Feature*` owner
- player fallout from stream shape changes -> `FeaturePlayer` owner

This prevents broad upstream changes from becoming unowned work.

## 13. Safe Automation Rules

- Never auto-merge protocol changes into the local core.
- Never overwrite local manifests without storing the previous version.
- Never classify a change as low risk if AppSign, WBI, login flow, or grpc metadata changed.
- Never ship after a critical upstream diff without running the relevant regressions.

The system should automate detection and reporting, not blind code modification.

## 14. First Implementation Milestones

Recommended order:

1. build `UpstreamFetcher`
2. build watched file filter
3. build `endpoint_manifest.json`
4. build `auth_policy_manifest.json`
5. build `signing_manifest.json`
6. build `DiffClassifier`
7. build feed, video, and auth regression suites
8. add gRPC and proto fingerprint manifests
9. add report generation and task emission

This sequence gets the highest-value early warning system running before the entire extractor is complete.

## 15. Success Criteria

The sync system is working correctly when:

- upstream protocol changes are detected within one sync cycle
- extracted manifests explain the behavior delta clearly
- regression suites run automatically for the affected surface
- reports point to the impacted local modules
- no one has to manually inspect every upstream commit to stay current

At that point, upstream drift becomes a managed maintenance process instead of an unpredictable breakage source.

