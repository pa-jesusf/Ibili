#!/usr/bin/env bash
# Runs request and offscreen Core Animation regressions on the Mac host, never a simulator.
# UIKit image/danmaku tests remain in the generic iOS build-for-testing target.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
OUTPUT="$PROJECT_ROOT/build/performance-host"
XCTEST_FRAMEWORKS="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
XCTEST_LIBRARIES="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
mkdir -p "$OUTPUT"
mkdir -p "$OUTPUT/PerformanceTests.xctest/Contents/MacOS"
cp tools/performance-host/Info.plist "$OUTPUT/PerformanceTests.xctest/Contents/Info.plist"
cargo build --manifest-path core/rust/Cargo.toml -p ibili_ffi
SOURCES="$PROJECT_ROOT/ios-app/IbiliApp/Sources"
xcrun swiftc -swift-version 5 -enable-testing -emit-library -emit-module -module-name Ibili \
    -I core/rust/crates/ibili_ffi/include -L core/rust/target/debug -libili_ffi \
    -Xlinker -rpath -Xlinker "$PROJECT_ROOT/core/rust/target/debug" \
    "$SOURCES/Bridge/BlockingWorkQueue.swift" "$SOURCES/Bridge/CoreClient.swift" \
    "$SOURCES/Bridge/CoreDTOs.swift" "$SOURCES/App/VideoLinkRequest.swift" \
    "$SOURCES/Bridge/InteractiveVideoDTOs.swift" \
    "$SOURCES/Features/Auth/LoginDTOs.swift" "$SOURCES/Features/Player/BiliHTTP.swift" \
    "$SOURCES/Features/Home/PlayUrlPrefetcher.swift" \
    "$SOURCES/DesignSystem/ImageDiskCache.swift" "$SOURCES/DesignSystem/Lists/CollectionItemState.swift" \
    "$SOURCES/DesignSystem/ExtendedCoverBackdrop.swift" "$SOURCES/DesignSystem/Components/MediaCardLayout.swift" \
    "$SOURCES/Features/VideoDetail/VideoDetailRepository.swift" "$SOURCES/Features/Offline/OfflineLibraryIndex.swift" \
    "$SOURCES/Features/Live/LiveDanmakuParser.swift" "$SOURCES/Features/Live/LiveMessageBuffer.swift" \
    "$SOURCES/Features/Search/SearchViewModel.swift" "$SOURCES/Features/Search/SearchTypes.swift" \
    "$SOURCES/Features/Search/RootSearchState.swift" \
    "$SOURCES/Features/Search/SearchCategories.swift" "$SOURCES/Features/VideoDetail/VideoInteractionService.swift" \
    "$SOURCES/Features/Player/Proxy/HLSProxyListener.swift" tools/performance-host/AppLog.swift \
    "$SOURCES/Features/Player/Runtime/PlayerSessionBehavior.swift" \
    "$SOURCES/Features/Player/Runtime/PlayerTimeControlObservation.swift" \
    "$SOURCES/Features/Player/Runtime/PlayerItemReadiness.swift" \
    "$SOURCES/Features/Player/Runtime/PlayerNowPlayingCoordinator.swift" \
    "$SOURCES/Features/Player/DanmakuBulletLayer.swift" \
    "$SOURCES/App/AppVersion.swift" \
    "$SOURCES/Features/Player/SponsorBlockTypes.swift" \
    "$SOURCES/Features/Player/SponsorBlockRepository.swift" \
    "$SOURCES/Features/Player/SponsorBlockPlaybackCoordinator.swift" \
    "$SOURCES/Features/Player/InteractiveExpression.swift" \
    "$SOURCES/Features/Player/InteractiveVideoCoordinator.swift" \
    -emit-module-path "$OUTPUT/Ibili.swiftmodule" -o "$OUTPUT/libIbili.dylib"
xcrun swiftc -swift-version 5 -emit-library -module-name PerformanceTests -I "$OUTPUT" -I core/rust/crates/ibili_ffi/include \
    -F "$XCTEST_FRAMEWORKS" -framework XCTest -Xlinker -rpath -Xlinker "$XCTEST_FRAMEWORKS" \
    -I "$XCTEST_LIBRARIES" -L "$XCTEST_LIBRARIES" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$XCTEST_LIBRARIES" \
    -L "$OUTPUT" -lIbili -Xlinker -rpath -Xlinker "$OUTPUT" \
    ios-app/IbiliApp/Tests/PerformanceRequestTests.swift \
    ios-app/IbiliApp/Tests/HLSProxyListenerTests.swift \
    ios-app/IbiliApp/Tests/ConcurrentPageRequestTests.swift \
    ios-app/IbiliApp/Tests/SearchViewModelTests.swift \
    ios-app/IbiliApp/Tests/SharedInfrastructureTests.swift \
    ios-app/IbiliApp/Tests/HomeCardPresentationTests.swift \
    ios-app/IbiliApp/Tests/ArtworkBackdropTests.swift \
    ios-app/IbiliApp/Tests/Runtime/PlayerSessionBehaviorTests.swift \
    ios-app/IbiliApp/Tests/Runtime/PlayerTimeControlObservationTests.swift \
    ios-app/IbiliApp/Tests/DanmakuBulletLayerTests.swift \
    ios-app/IbiliApp/Tests/SponsorBlockTests.swift \
    ios-app/IbiliApp/Tests/SponsorBlockPlaybackTests.swift \
    ios-app/IbiliApp/Tests/InteractiveVideoTests.swift \
    ios-app/IbiliApp/Tests/PlayerNowPlayingTests.swift \
    -o "$OUTPUT/PerformanceTests.xctest/Contents/MacOS/PerformanceTests"
xcrun xctest "$OUTPUT/PerformanceTests.xctest"
