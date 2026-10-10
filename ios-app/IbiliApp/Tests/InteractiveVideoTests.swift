import AVFoundation
import Combine
import XCTest
@testable import Ibili

@MainActor
final class InteractiveVideoTests: XCTestCase {
    private let bv = "BV1UE411y7Wy"
    private let info = InteractiveVideoInfoDTO(graphVersion: 634464, historyNode: nil, msg: nil, needReload: nil)
    private let variable = InteractiveVariableDTO(idV2: "$loop", value: 1)

    private func node(_ edge: Int64 = 1, cid: Int64 = 100, questions: [InteractiveQuestionDTO], leaf: Bool = false) -> InteractiveNodeDTO {
        InteractiveNodeDTO(edgeID: edge, isLeaf: leaf ? 1 : 0,
                           storyList: [.init(edgeID: edge, cid: cid)], hiddenVars: [variable],
                           edges: .init(questions: questions))
    }
    private func drain() async { for _ in 0..<100 { await Task.yield() } }
    private func bind(_ coordinator: InteractiveVideoCoordinator, position: Double = 0) async -> StoryPlayer {
        let item = StoryItem(asset: AVMutableComposition())
        let player = StoryPlayer(playerItem: item)
        player.position = position
        coordinator.bind(player: player, item: item, bvid: bv, cid: 100, info: info, allowed: true)
        await drain()
        return player
    }

    func testConditionsAndAssignmentsUseNumericPrecedenceAndAreAtomic() throws {
        XCTAssertEqual(try InteractiveExpression.evaluate("$loop>=1 && (3+4*2)==11", variables: ["$loop": 1]), 1)
        XCTAssertEqual(try InteractiveExpression.evaluate("!0 || -2 > 3", variables: [:]), 1)
        XCTAssertEqual(try InteractiveExpression.evaluate("1 || 0 && 0", variables: [:]), 0)
        XCTAssertEqual(try InteractiveExpression.applying("$loop=2\n$loop=$loop+1", to: ["$loop": 1])["$loop"], 3)
        XCTAssertEqual(try InteractiveExpression.applying("$loop=$loop+1;$loop=$loop*3", to: ["$loop": 1])["$loop"], 6)
        for source in ["$missing>0", "1/0", "1%0", "NaN", "1);evil()", String(repeating: "!", count: 100) + "1"] {
            XCTAssertThrowsError(try InteractiveExpression.evaluate(source, variables: [:]), source)
        }
        XCTAssertThrowsError(try InteractiveExpression.applying("$loop=2;$missing=3", to: ["$loop": 1]))
    }

    func testTimingMatchesWebPlayerEndTimedEndAndMidVideo() {
        XCTAssertEqual(InteractiveQuestionDTO(startTimeR: 300).triggerSeconds(videoDuration: 100), 100)
        XCTAssertEqual(InteractiveQuestionDTO(duration: 5000).triggerSeconds(videoDuration: 100), 95)
        XCTAssertEqual(InteractiveQuestionDTO(type: 4, startTime: 40000, duration: 5000).triggerSeconds(videoDuration: 100), 40)
        XCTAssertEqual(InteractiveQuestionDTO(type: 4, startTimeR: 20000, duration: 5000).triggerSeconds(videoDuration: 100), 80)
    }

    func testEndChoicesAndBranchCIDDoNotUseOrdinaryPagesOrInheritProgress() async {
        let choice = InteractiveChoiceDTO(id: 22453494, cid: 245681715, option: "继续", nativeAction: "$loop=$loop+1")
        let root = node(questions: [.init(choices: [choice])])
        var requests: [Int64] = [], transitions: [Int64] = []
        let c = InteractiveVideoCoordinator { _, _, edge, _, _ in
            requests.append(edge)
            return edge == 0 ? root : self.node(edge, cid: choice.cid, questions: [], leaf: true)
        }
        let player = await bind(c, position: 99)
        defer { c.reset() }
        c.transition = { cid, resumeMs in
            XCTAssertEqual(resumeMs, 0)
            transitions.append(cid)
            player.replaceCurrentItem(with: StoryItem(asset: AVMutableComposition()))
            player.position = 0
            c.replaceItemBinding(player: player, item: player.currentItem!)
            return true
        }
        XCTAssertEqual(c.presentation.phase, .hidden)
        player.position = 100
        XCTAssertTrue(c.handleCompletion())
        XCTAssertEqual(c.presentation.phase, .choices)
        XCTAssertTrue(c.presentation.showsHistoryControl)
        c.choose(choice); c.choose(choice)
        await drain()
        XCTAssertEqual(requests, [0, choice.id])
        XCTAssertEqual(transitions, [choice.cid])
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(c.variables["$loop"], 2)
        XCTAssertEqual(c.node?.edgeID, choice.id)
        XCTAssertEqual(c.presentation.phase, .hidden)
        XCTAssertFalse(c.presentation.showsHistoryControl)
        player.position = 100; _ = c.handleCompletion()
        XCTAssertEqual(c.presentation.phase, .ending)
        XCTAssertFalse(c.presentation.showsHistoryControl)
    }

    func testFailedBranchRetryDoesNotApplyVariableActionTwice() async {
        let choice = InteractiveChoiceDTO(id: 2, cid: 200, nativeAction: "$loop=$loop+1")
        let root = node(questions: [.init(choices: [choice])])
        var attempts = 0
        let c = InteractiveVideoCoordinator { _, _, edge, _, _ in
            if edge == 0 { return root }
            attempts += 1
            if attempts == 1 { throw InteractiveVideoCoordinator.StoryError("断网") }
            return self.node(2, cid: 200, questions: [], leaf: true)
        }
        let player = await bind(c, position: 100)
        defer { c.reset(); _ = player }
        c.transition = { _, _ in true }
        _ = c.handleCompletion(); c.choose(choice)
        await drain()
        XCTAssertEqual(c.presentation.phase, .failed)
        XCTAssertEqual(c.variables["$loop"], 1)
        c.retry(); await drain()
        XCTAssertEqual(c.variables["$loop"], 2)
        XCTAssertEqual(attempts, 2)
    }

    func testMidVideoDecisionChangesVariablesAndSendsChoiceWithoutSwitchingCID() async {
        let mid = InteractiveChoiceDTO(id: 50, option: "加一", nativeAction: "$loop=$loop+1", platformAction: "SEEK 60")
        let end = InteractiveChoiceDTO(id: 2, cid: 200, condition: "$loop==2")
        let root = node(questions: [.init(type: 4, startTime: 40000, choices: [mid]), .init(choices: [end])])
        var submitted: [Int64] = [], transitions: [Int64] = []
        let c = InteractiveVideoCoordinator { _, _, edge, choices, _ in
            if edge == 0 { return root }
            submitted = choices
            return self.node(2, cid: 200, questions: [], leaf: true)
        }
        let player = await bind(c, position: 40)
        defer { c.reset() }
        c.seek = { seconds in player.position = seconds; return true }
        c.transition = { cid, _ in transitions.append(cid); return true }
        XCTAssertEqual(c.presentation.phase, .choices)
        XCTAssertTrue(c.isBlocking)
        c.choose(mid); await drain()
        XCTAssertEqual(player.position, 60)
        XCTAssertTrue(transitions.isEmpty)
        XCTAssertEqual(c.variables["$loop"], 2)
        player.position = 100; _ = c.handleCompletion()
        c.choose(end); await drain()
        XCTAssertEqual(submitted, [50])
        XCTAssertEqual(transitions, [200])
    }

    func testConditionalChoicesAndHiddenDefault() async {
        let hidden = InteractiveChoiceDTO(id: 2, cid: 200, condition: "$loop==1", isDefault: 1, isHidden: 1)
        let rejected = InteractiveChoiceDTO(id: 3, cid: 300, option: "错误", condition: "$loop<1")
        let root = node(questions: [.init(type: 0, choices: [hidden, rejected])])
        let c = InteractiveVideoCoordinator { _, _, edge, _, _ in edge == 0 ? root : self.node(2, cid: 200, questions: [], leaf: true) }
        let player = await bind(c, position: 99)
        defer { c.reset(); _ = player }
        var transitioned = false
        c.transition = { _, _ in transitioned = true; return true }
        c.playbackStateChanged(allowed: false)
        player.position = 100
        _ = c.handleCompletion(); await drain()
        XCTAssertFalse(transitioned)
        c.playbackStateChanged(allowed: true); await drain()
        XCTAssertTrue(transitioned)
        XCTAssertEqual(c.node?.edgeID, 2)
    }

    func testCountdownStopsOnPauseAndLostFocusThenSelectsOnlyEligibleDefault() async {
        let valid = InteractiveChoiceDTO(id: 2, cid: 200, option: "默认", condition: "$loop==1", isDefault: 1)
        let invalid = InteractiveChoiceDTO(id: 3, cid: 300, condition: "$loop==0", isDefault: 1)
        let root = node(questions: [.init(duration: 5000, pauseVideo: 0, choices: [invalid, valid])])
        let c = InteractiveVideoCoordinator { _, _, edge, _, _ in edge == 0 ? root : self.node(edge, cid: 200, questions: [], leaf: true) }
        let player = await bind(c, position: 95)
        defer { c.reset() }
        var cid: Int64 = 0
        c.transition = { value, _ in cid = value; return true }
        c.updateCountdown(elapsed: 3)
        XCTAssertEqual(c.presentation.secondsRemaining, 5)
        player.playing = true
        c.updateCountdown(elapsed: 2)
        XCTAssertEqual(c.presentation.secondsRemaining, 3)
        c.playbackStateChanged(allowed: false)
        c.updateCountdown(elapsed: 50)
        XCTAssertEqual(c.presentation.secondsRemaining, 3)
        c.playbackStateChanged(allowed: true)
        c.updateCountdown(elapsed: 3); await drain()
        XCTAssertEqual(cid, 200)
    }

    func testQualityReplacementKeepsNodeVariablesAndReinstallsBoundary() async {
        let root = node(questions: [.init(type: 4, startTime: 50000, choices: [.init(id: 10)])])
        var fetches = 0
        let c = InteractiveVideoCoordinator { _, _, _, _, _ in fetches += 1; return root }
        let player = await bind(c)
        defer { c.reset() }
        let replacement = StoryItem(asset: AVMutableComposition())
        player.replaceCurrentItem(with: replacement)
        c.bind(player: player, item: replacement, bvid: bv, cid: 100, info: nil, allowed: true)
        player.position = 50; player.fireBoundaries(); await drain()
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(c.variables["$loop"], 1)
        XCTAssertEqual(c.presentation.phase, .choices)
    }

    func testLateNodeResponseCannotChangeReplacementSession() async {
        var finish: CheckedContinuation<InteractiveNodeDTO, Error>?
        let c = InteractiveVideoCoordinator { _, _, _, _, _ in try await withCheckedThrowingContinuation { finish = $0 } }
        let player = await bind(c)
        c.reset()
        finish?.resume(returning: node(questions: [.init(choices: [.init(id: 2, cid: 200)])]))
        await drain()
        XCTAssertFalse(c.isEnabled)
        XCTAssertNil(c.node)
        XCTAssertEqual(c.presentation.phase, .hidden)
        _ = player
    }

    func testCompletionWhileInitialNodeLoadsWaitsInsteadOfOrdinaryAutoplay() async {
        var finish: CheckedContinuation<InteractiveNodeDTO, Error>?
        let c = InteractiveVideoCoordinator { _, _, _, _, _ in try await withCheckedThrowingContinuation { finish = $0 } }
        let player = await bind(c, position: 100)
        defer { c.reset() }
        XCTAssertTrue(c.handleCompletion())
        XCTAssertTrue(c.isBlocking)
        finish?.resume(returning: node(questions: [.init(choices: [.init(id: 2, cid: 200, option: "继续")])]))
        await drain()
        XCTAssertEqual(c.presentation.phase, .choices)
        XCTAssertTrue(c.isBlocking)
        _ = player
    }

    func testUnknownConditionAndUnsupportedSpecialNeverChooseArbitraryBranch() async {
        for q in [InteractiveQuestionDTO(type: 127, choices: [.init(id: 2, cid: 200)]),
                  .init(type: 3, choices: [.init(id: 2, cid: 200)]),
                  .init(choices: [.init(id: 2, cid: 200, condition: "$missing>0")])] {
            let root = node(questions: [q])
            let c = InteractiveVideoCoordinator { _, _, _, _, _ in root }
            let player = await bind(c, position: 100)
            c.transition = { _, _ in XCTFail("Must not guess unsupported conditions"); return true }
            _ = c.handleCompletion(); await drain()
            XCTAssertEqual(c.presentation.phase, .failed)
            XCTAssertTrue(c.isBlocking)
            c.reset(); _ = player
        }
    }

    func testForeignChoiceAndMismatchedNodeNeverInstallSource() async {
        let choice = InteractiveChoiceDTO(id: 2, cid: 200)
        let root = node(questions: [.init(choices: [choice])])
        let c = InteractiveVideoCoordinator { _, _, edge, _, _ in edge == 0 ? root : self.node(999, questions: []) }
        let player = await bind(c, position: 100)
        defer { c.reset(); _ = player }
        c.transition = { _, _ in XCTFail("Mismatched node must not install its CID"); return true }
        _ = c.handleCompletion()
        c.choose(.init(id: 2, cid: 999))
        XCTAssertEqual(c.presentation.phase, .choices)
        c.choose(choice); await drain()
        XCTAssertEqual(c.presentation.phase, .failed)
    }

    func testGateReentryCannotSubmitDefaultAlongsideClickedBranch() async {
        let clicked = InteractiveChoiceDTO(id: 2, cid: 200, option: "选择我")
        let automatic = InteractiveChoiceDTO(id: 3, cid: 300, option: "默认", isDefault: 1)
        let root = node(questions: [.init(duration: 5000, pauseVideo: 0, choices: [clicked, automatic])])
        var fetches: [Int64] = [], transitions: [Int64] = []
        let c = InteractiveVideoCoordinator { _, _, edge, _, _ in
            fetches.append(edge)
            return edge == 0 ? root : self.node(edge, cid: edge * 100, questions: [], leaf: true)
        }
        let player = await bind(c, position: 95)
        defer { c.reset() }
        player.playing = true
        c.gateChanged = { c.playbackStateChanged(allowed: true) }
        c.transition = { cid, _ in transitions.append(cid); return true }
        c.choose(clicked); await drain()
        XCTAssertEqual(fetches, [0, 2])
        XCTAssertEqual(transitions, [200])
    }

    func testTimedHiddenBranchWaitsForCountdownInsteadOfCuttingOffLastSeconds() async {
        let choice = InteractiveChoiceDTO(id: 2, cid: 200, isDefault: 1)
        let root = node(questions: [.init(type: 0, duration: 5000, pauseVideo: 0, choices: [choice])])
        let c = InteractiveVideoCoordinator { _, _, edge, _, _ in edge == 0 ? root : self.node(edge, cid: 200, questions: [], leaf: true) }
        let player = await bind(c, position: 95)
        defer { c.reset() }
        player.playing = true
        var transitions = 0
        c.transition = { _, _ in transitions += 1; return true }
        XCTAssertTrue(c.presentation.choices.isEmpty)
        c.playbackStateChanged(allowed: true); await drain()
        XCTAssertEqual(transitions, 0)
        c.updateCountdown(elapsed: 4)
        XCTAssertEqual(transitions, 0)
        c.updateCountdown(elapsed: 1); await drain()
        XCTAssertEqual(transitions, 1)
    }

    func testCompletionReentryDuringRestartKeepsLoadingGate() async {
        let root = node(questions: [], leaf: true)
        var finish: CheckedContinuation<InteractiveNodeDTO, Error>?
        let c = InteractiveVideoCoordinator { _, _, _, _, portal in
            if portal == 1 { return try await withCheckedThrowingContinuation { finish = $0 } }
            return root
        }
        let player = await bind(c, position: 99)
        defer { c.reset(); _ = player }
        c.transition = { _, _ in true }
        c.gateChanged = { if c.isBlocking { _ = c.handleCompletion() } }
        c.restart(); await drain()
        XCTAssertEqual(c.presentation.phase, .loading)
        XCTAssertTrue(c.isBlocking)
        finish?.resume(returning: root); await drain()
        XCTAssertEqual(c.presentation.phase, .hidden)
        XCTAssertFalse(c.isBlocking)
    }

    func testSeekingBackFromLeafEndingRestoresNativePlayback() async {
        let root = node(questions: [], leaf: true)
        let c = InteractiveVideoCoordinator { _, _, _, _, _ in root }
        let player = await bind(c, position: 100)
        defer { c.reset() }
        _ = c.handleCompletion()
        XCTAssertEqual(c.presentation.phase, .ending)
        player.position = 10
        NotificationCenter.default.post(name: .AVPlayerItemTimeJumped, object: player.currentItem)
        await drain()
        XCTAssertEqual(c.presentation.phase, .hidden)
        XCTAssertFalse(c.isBlocking)
    }

    func testMediaFailureRetriesPreparedNodeWithoutResubmittingStoryDecision() async {
        let choice = InteractiveChoiceDTO(id: 2, cid: 200, nativeAction: "$loop=$loop+1")
        let root = node(questions: [.init(choices: [choice])])
        var fetches = 0, attempts = 0
        let c = InteractiveVideoCoordinator { _, _, edge, _, _ in
            fetches += 1
            return edge == 0 ? root : self.node(edge, cid: 200, questions: [], leaf: true)
        }
        let player = await bind(c, position: 100)
        defer { c.reset(); _ = player }
        c.transition = { _, _ in
            attempts += 1
            if attempts == 1 { throw InteractiveVideoCoordinator.StoryError("媒体加载失败") }
            return true
        }
        _ = c.handleCompletion(); c.choose(choice); await drain()
        XCTAssertEqual(c.variables["$loop"], 1)
        c.retry(); await drain()
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(c.variables["$loop"], 2)
    }

    func testMetadataCompletionArrivingDuringFetchIsPreserved() async {
        var finish: CheckedContinuation<InteractiveVideoInfoDTO, Error>?
        let root = node(questions: [], leaf: true)
        let c = InteractiveVideoCoordinator { _, _, _, _, _ in root }
        let player = StoryPlayer(playerItem: StoryItem(asset: AVMutableComposition()))
        player.position = 100
        defer { c.reset() }
        c.refreshInfo = { try await withCheckedThrowingContinuation { finish = $0 } }
        c.requireMetadata(player: player, item: player.currentItem!, bvid: bv, cid: 100, allowed: true)
        await drain()
        XCTAssertTrue(c.isTransitioning)
        _ = c.handleCompletion()
        finish?.resume(returning: info); await drain()
        XCTAssertEqual(c.presentation.phase, .ending)
        XCTAssertTrue(c.isBlocking)
    }

    func testMetadataReplacementRejectsOldItemAndRetryBindsActualItem() async {
        var finish: CheckedContinuation<InteractiveVideoInfoDTO, Error>?
        let root = node(questions: [.init(choices: [.init(id: 2, cid: 200, option: "继续")])])
        let c = InteractiveVideoCoordinator { _, _, _, _, _ in root }
        let player = StoryPlayer(playerItem: StoryItem(asset: AVMutableComposition()))
        defer { c.reset() }
        c.refreshInfo = { try await withCheckedThrowingContinuation { finish = $0 } }
        c.requireMetadata(player: player, item: player.currentItem!, bvid: bv, cid: 100, allowed: true)
        await drain()
        let next = StoryItem(asset: AVMutableComposition())
        player.replaceCurrentItem(with: next)
        finish?.resume(returning: info); await drain()
        XCTAssertEqual(c.presentation.phase, .failed)
        XCTAssertNil(c.node)
        c.refreshInfo = { self.info }
        c.retry(); await drain()
        player.position = 100; _ = c.handleCompletion()
        XCTAssertEqual(c.presentation.phase, .choices)
    }

    func testExpiredGraphReloadsMetadataAndRestartsWithNewRoot() async {
        let choice = InteractiveChoiceDTO(id: 2, cid: 200)
        let root = node(questions: [.init(choices: [choice])])
        var graphs: [Int64] = [], portals: [Int] = []
        let c = InteractiveVideoCoordinator { _, graph, edge, _, portal in
            graphs.append(graph); portals.append(portal)
            if edge == 2 { throw CoreError(category: "api", message: "图已修改", code: 99003) }
            return root
        }
        let player = await bind(c, position: 100)
        defer { c.reset() }
        c.refreshInfo = { .init(graphVersion: 999, historyNode: nil, msg: nil, needReload: nil) }
        c.transition = { _, _ in player.position = 0; return true }
        _ = c.handleCompletion(); c.choose(choice); await drain()
        XCTAssertEqual(c.presentation.phase, .failed)
        c.retry(); await drain()
        XCTAssertEqual(graphs, [634464, 634464, 999])
        XCTAssertEqual(portals, [0, 0, 1])
        XCTAssertEqual(c.presentation.phase, .hidden)
    }

    func testRewindRestoresDecisionVariablesMidChoicesAndPositionBeforeChoosingDifferentBranch() async {
        let mid = InteractiveChoiceDTO(id: 50, nativeAction: "$loop=$loop+1")
        let first = InteractiveChoiceDTO(id: 2, cid: 200, nativeAction: "$loop=$loop+10")
        let other = InteractiveChoiceDTO(id: 3, cid: 300, condition: "$loop==2", nativeAction: "$loop=$loop*3")
        let root = node(questions: [.init(type: 4, startTime: 40000, choices: [mid]), .init(choices: [first, other])])
        var requests: [(Int64, [Int64], Int)] = []
        let c = InteractiveVideoCoordinator { _, _, edge, choices, portal in
            requests.append((edge, choices, portal))
            return edge == 0 || edge == 1 ? root : self.node(edge, cid: edge * 100, questions: [], leaf: true)
        }
        let player = await bind(c, position: 40)
        defer { c.reset() }
        c.transition = { _, resume in
            player.replaceCurrentItem(with: StoryItem(asset: AVMutableComposition()))
            player.position = Double(resume) / 1000
            c.replaceItemBinding(player: player, item: player.currentItem!)
            NotificationCenter.default.post(name: .AVPlayerItemTimeJumped, object: player.currentItem)
            return true
        }
        c.choose(mid); await drain()
        player.position = 100; _ = c.handleCompletion()
        let rootID = c.history[0].id
        c.choose(first); await drain()
        XCTAssertEqual(c.variables["$loop"], 12)
        XCTAssertEqual(c.history.count, 2)
        c.rewind(to: rootID); await drain()
        XCTAssertEqual(c.variables["$loop"], 2)
        XCTAssertEqual(player.position, 100)
        XCTAssertEqual(c.presentation.phase, .choices)
        XCTAssertTrue(c.isBlocking)
        XCTAssertEqual(c.history.count, 1)
        XCTAssertEqual(requests.last?.0, 1)
        XCTAssertEqual(requests.last?.1, [])
        XCTAssertEqual(requests.last?.2, 1)
        c.choose(other); await drain()
        XCTAssertEqual(c.variables["$loop"], 6)
        XCTAssertEqual(c.node?.edgeID, 3)
        XCTAssertEqual(requests.last?.1, [50])
        XCTAssertEqual(c.history.map(\.edgeID), [1, 3])
    }

    func testServerHistoryRewindUsesCheckpointPositionAndReturnedVariables() async {
        var root = node(1, cid: 100, questions: [.init(duration: 10000, choices: [.init(id: 2, cid: 200, condition: "$loop==7")])])
        root.hiddenVars = [.init(idV2: "$loop", value: 7)]
        var initial = node(3, cid: 300, questions: [], leaf: true)
        initial.storyList = [.init(edgeID: 1, cid: 100, title: "开场", startPos: 90000), .init(edgeID: 3, cid: 300, title: "结局")]
        let c = InteractiveVideoCoordinator { _, _, edge, _, portal in portal == 1 ? root : initial }
        let player = StoryPlayer(playerItem: StoryItem(asset: AVMutableComposition()))
        defer { c.reset() }
        let historyInfo = InteractiveVideoInfoDTO(graphVersion: 634464, historyNode: .init(nodeID: 3, cid: 300, title: "结局"), msg: nil, needReload: nil)
        c.bind(player: player, item: player.currentItem!, bvid: bv, cid: 300, info: historyInfo, allowed: true)
        await drain()
        var restoredPosition: Int64 = 0
        c.transition = { cid, resume in
            XCTAssertEqual(cid, 100); restoredPosition = resume
            player.position = Double(resume) / 1000
            return true
        }
        c.rewind(to: c.history[0].id); await drain()
        XCTAssertEqual(restoredPosition, 90000)
        XCTAssertEqual(c.variables["$loop"], 7)
        XCTAssertEqual(c.presentation.phase, .choices)
        XCTAssertEqual(c.history.map(\.edgeID), [1])
    }

    func testBacktrackingRestrictionAndForeignHistoryRejectWithoutRequests() async {
        var root = node(questions: [], leaf: true)
        root.noBacktracking = 1
        var fetches = 0, transitions = 0
        let c = InteractiveVideoCoordinator { _, _, _, _, _ in fetches += 1; return root }
        let player = await bind(c)
        defer { c.reset(); _ = player }
        c.transition = { _, _ in transitions += 1; return true }
        XCTAssertTrue(c.history.isEmpty)
        c.rewind(to: UUID()); await drain()
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(transitions, 0)
    }

    func testFailedRewindRetainsPathAndRetryReusesNodeWithoutApplyingActions() async {
        let choice = InteractiveChoiceDTO(id: 2, cid: 200, nativeAction: "$loop=$loop+1")
        let root = node(questions: [.init(choices: [choice])])
        var rewindRequests = 0, rewindAttempts = 0
        let c = InteractiveVideoCoordinator { _, _, edge, _, portal in
            if portal == 1 { rewindRequests += 1; return root }
            return edge == 0 ? root : self.node(2, cid: 200, questions: [], leaf: true)
        }
        let player = await bind(c, position: 100)
        defer { c.reset() }
        c.transition = { cid, resume in
            if cid == 100 {
                rewindAttempts += 1
                if rewindAttempts == 1 { throw InteractiveVideoCoordinator.StoryError("断网") }
            }
            player.position = Double(resume) / 1000
            return true
        }
        let rootID = c.history[0].id
        _ = c.handleCompletion(); c.choose(choice); await drain()
        c.rewind(to: rootID); await drain()
        XCTAssertEqual(c.presentation.phase, .failed)
        XCTAssertEqual(c.history.count, 2)
        XCTAssertEqual(c.variables["$loop"], 2)
        c.retry(); await drain()
        XCTAssertEqual(rewindRequests, 1)
        XCTAssertEqual(rewindAttempts, 2)
        XCTAssertEqual(c.variables["$loop"], 1)
        XCTAssertEqual(c.history.count, 1)
        XCTAssertEqual(c.presentation.phase, .choices)
    }

    func testNativeReadinessFailureRetryPreservesOutgoingDecisionCheckpoint() async {
        let choice = InteractiveChoiceDTO(id: 2, cid: 200, nativeAction: "$loop=$loop+1")
        let root = node(questions: [.init(choices: [choice])])
        var requests: [Int64] = [], attempts = 0
        let c = InteractiveVideoCoordinator { _, _, edge, _, _ in
            requests.append(edge)
            return edge == 0 || edge == 1 ? root : self.node(2, cid: 200, questions: [], leaf: true)
        }
        let player = await bind(c, position: 100)
        defer { c.reset() }
        let rootID = c.history[0].id
        c.transition = { cid, resume in
            attempts += 1
            if attempts == 1 {
                let failed = ReadinessItem(asset: AVMutableComposition())
                player.replaceCurrentItem(with: failed)
                player.position = 0
                c.replaceItemBinding(player: player, item: failed)
                failed.publish(.failed)
                try await PlayerItemReadiness.waitUntilReady(failed, player: player)
            }
            player.replaceCurrentItem(with: StoryItem(asset: AVMutableComposition()))
            player.position = Double(resume) / 1000
            c.replaceItemBinding(player: player, item: player.currentItem!)
            if cid == 100 { XCTAssertEqual(resume, 100_000) }
            return true
        }
        _ = c.handleCompletion(); c.choose(choice); await drain()
        XCTAssertEqual(c.presentation.phase, .failed)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(c.variables["$loop"], 1)
        c.retry(); await drain()
        XCTAssertEqual(c.node?.edgeID, 2)
        XCTAssertEqual(c.variables["$loop"], 2)
        c.rewind(to: rootID); await drain()
        XCTAssertEqual(player.position, 100)
        XCTAssertEqual(c.variables["$loop"], 1)
        XCTAssertEqual(c.presentation.phase, .choices)
        XCTAssertEqual(requests, [0, 2, 1])
    }

    func testRecoveryRetiringUnknownItemEndsTransitionAndAllowsRetry() async {
        let choice = InteractiveChoiceDTO(id: 2, cid: 200)
        let root = node(questions: [.init(choices: [choice])])
        var branchRequests = 0, attempts = 0
        let c = InteractiveVideoCoordinator { _, _, edge, _, _ in
            if edge == 0 { return root }
            branchRequests += 1
            return self.node(2, cid: 200, questions: [], leaf: true)
        }
        let original = await bind(c, position: 100)
        let waitingItem = ReadinessItem(asset: AVMutableComposition())
        let recovered = StoryPlayer(playerItem: StoryItem(asset: AVMutableComposition()))
        defer { c.reset() }
        c.transition = { _, _ in
            attempts += 1
            if attempts == 1 {
                original.replaceCurrentItem(with: waitingItem)
                original.position = 0
                c.replaceItemBinding(player: original, item: waitingItem)
                try await PlayerItemReadiness.waitUntilReady(waitingItem, player: original)
            } else {
                recovered.replaceCurrentItem(with: StoryItem(asset: AVMutableComposition()))
                c.replaceItemBinding(player: recovered, item: recovered.currentItem!)
            }
            return true
        }
        _ = c.handleCompletion(); c.choose(choice); await drain()
        XCTAssertEqual(c.presentation.phase, .loading)
        original.replaceCurrentItem(with: nil)
        c.replaceItemBinding(player: recovered, item: recovered.currentItem!)
        await drain()
        XCTAssertEqual(waitingItem.status, .unknown)
        XCTAssertEqual(c.presentation.phase, .failed)
        XCTAssertFalse(c.isTransitioning)
        c.retry(); await drain()
        XCTAssertEqual(c.node?.edgeID, 2)
        XCTAssertEqual(branchRequests, 1)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(c.presentation.phase, .hidden)
    }

    func testLateRewindCannotRestoreClosedSession() async {
        let choice = InteractiveChoiceDTO(id: 2, cid: 200)
        let root = node(questions: [.init(choices: [choice])])
        var finish: CheckedContinuation<InteractiveNodeDTO, Error>?
        let c = InteractiveVideoCoordinator { _, _, edge, _, portal in
            if portal == 1 { return try await withCheckedThrowingContinuation { finish = $0 } }
            return edge == 0 ? root : self.node(2, cid: 200, questions: [], leaf: true)
        }
        let player = await bind(c, position: 100)
        defer { c.reset(); _ = player }
        var transitions = 0
        c.transition = { _, _ in transitions += 1; return true }
        let rootID = c.history[0].id
        _ = c.handleCompletion(); c.choose(choice); await drain()
        c.rewind(to: rootID); await drain()
        c.reset(); finish?.resume(returning: root); await drain()
        XCTAssertEqual(transitions, 1)
        XCTAssertTrue(c.history.isEmpty)
        XCTAssertNil(c.node)
        XCTAssertEqual(c.presentation.phase, .hidden)
    }

    func testFloatingPromptDisappearsDuringPlaybackAndOffRouteWithoutCountdownChurn() async {
        let root = node(questions: [.init(duration: 5000, pauseVideo: 0, choices: [.init(id: 2, cid: 200, isDefault: 1)])])
        let c = InteractiveVideoCoordinator { _, _, _, _, _ in root }
        var visibility: [Bool] = []
        let observation = c.floatingPresentationPublisher.sink { visibility.append($0) }
        let player = await bind(c, position: 0)
        defer { c.reset(); observation.cancel() }
        XCTAssertEqual(visibility, [false, true, false])
        XCTAssertFalse(c.history.isEmpty)
        XCTAssertFalse(c.presentation.showsHistoryControl)
        player.position = 95; player.playing = true
        c.playbackStateChanged(allowed: true)
        XCTAssertEqual(visibility.last, true)
        XCTAssertTrue(c.presentation.showsHistoryControl)
        let beforeCountdown = visibility
        c.updateCountdown(elapsed: 1)
        XCTAssertEqual(visibility, beforeCountdown)
        c.playbackStateChanged(allowed: false)
        XCTAssertEqual(visibility.last, false)
        c.playbackStateChanged(allowed: true)
        XCTAssertEqual(visibility.last, true)
        player.position = 0
        c.playbackStateChanged(allowed: true)
        XCTAssertEqual(visibility.last, false)
        XCTAssertFalse(c.presentation.showsHistoryControl)
        c.reset()
        XCTAssertFalse(visibility.last!)
    }

    func testFloatingPromptIsHiddenInPictureInPictureAndCoveredScenesWhileTimelineContinues() async {
        let root = node(questions: [.init(duration: 5000, pauseVideo: 0, choices: [.init(id: 2, cid: 200, isDefault: 1)])])
        let c = InteractiveVideoCoordinator { _, _, _, _, _ in root }
        let player = await bind(c, position: 95)
        player.playing = true
        defer { c.reset() }
        var state = PlayerSessionBehaviorState()
        var visible = false
        let observation = c.floatingPresentationPublisher.sink { visible = $0 }
        defer { observation.cancel() }
        func synchronize() {
            c.playbackStateChanged(allowed: state.hasPlaybackFocus && state.isInterfacePresentingPlayer && !state.systemTransitionIsActive,
                                   presentationAllowed: state.canPresentFloatingPlayerUI)
        }
        state.apply(.interfaceActivated); synchronize()
        XCTAssertTrue(visible)
        state.apply(.systemTransitionChanged(true)); synchronize()
        XCTAssertFalse(visible)
        state.apply(.systemTransitionChanged(false)); synchronize()
        XCTAssertTrue(visible)
        state.apply(.pictureInPictureTransition(.started)); synchronize()
        XCTAssertFalse(visible)
        state.apply(.interfaceDeactivated); synchronize()
        XCTAssertTrue(state.hasPlaybackFocus)
        XCTAssertTrue(state.isInterfacePresentingPlayer)
        XCTAssertFalse(visible)
        c.updateCountdown(elapsed: 1)
        XCTAssertEqual(c.presentation.secondsRemaining, 4)
        state.apply(.pictureInPictureTransition(.stopped(.restored)))
        state.apply(.interfaceActivated); synchronize()
        XCTAssertTrue(visible)
        state.apply(.interfaceDeactivated); synchronize()
        XCTAssertFalse(visible)
    }

    func testRewindWaitsForReplacementSeekBeforeExposingChoicesAndCountdown() async {
        let choice = InteractiveChoiceDTO(id: 2, cid: 200, isDefault: 1)
        let root = node(questions: [.init(duration: 10000, pauseVideo: 0, choices: [choice])])
        let c = InteractiveVideoCoordinator { _, _, edge, _, _ in
            edge == 0 || edge == 1 ? root : self.node(2, cid: 200, questions: [], leaf: true)
        }
        let player = await bind(c, position: 100)
        defer { c.reset() }
        var finishSeek: CheckedContinuation<Bool, Never>?
        c.transition = { cid, resume in
            player.replaceCurrentItem(with: StoryItem(asset: AVMutableComposition()))
            player.position = 0
            c.replaceItemBinding(player: player, item: player.currentItem!)
            if cid == 100 {
                _ = await withCheckedContinuation { finishSeek = $0 }
                player.position = Double(resume) / 1000
                NotificationCenter.default.post(name: .AVPlayerItemTimeJumped, object: player.currentItem)
            }
            return true
        }
        let rootID = c.history[0].id
        _ = c.handleCompletion(); c.choose(choice); await drain()
        c.rewind(to: rootID); await drain()
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(c.presentation.phase, .loading)
        XCTAssertTrue(c.isTransitioning)
        XCTAssertTrue(c.presentation.choices.isEmpty)
        c.choose(choice)
        XCTAssertEqual(c.history.count, 2)
        finishSeek?.resume(returning: true); await drain()
        XCTAssertEqual(player.position, 90)
        XCTAssertEqual(c.presentation.secondsRemaining, 10)
        XCTAssertEqual(c.history.count, 1)
    }

    func testItemReadinessWaitsAndCancelsWithoutHangingOnUnknownItem() async {
        let item = ReadinessItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: item)
        var finished = false
        let waiting = Task { try await PlayerItemReadiness.waitUntilReady(item, player: player); finished = true }
        await drain()
        XCTAssertFalse(finished)
        item.publish(.readyToPlay)
        do { try await waiting.value } catch { XCTFail(error.localizedDescription) }
        XCTAssertTrue(finished)
        let unknown = ReadinessItem(asset: AVMutableComposition())
        player.replaceCurrentItem(with: unknown)
        let cancelled = Task { try await PlayerItemReadiness.waitUntilReady(unknown, player: player) }
        await drain(); cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled readiness must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        let failed = ReadinessItem(asset: AVMutableComposition())
        failed.publish(.failed)
        player.replaceCurrentItem(with: failed)
        do { try await PlayerItemReadiness.waitUntilReady(failed, player: player); XCTFail("Failed item must not become ready") }
        catch { XCTAssertFalse(error is CancellationError) }
    }

    func testRealAVPlayerChangesBranchOnSamePlayerAndStartsAtZero() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("story.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000))
        buffer.frameLength = 80_000
        buffer.floatChannelData![0].update(repeating: 0, count: 80_000)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let original = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: original)
        await ready(original)
        _ = await player.seek(to: CMTime(seconds: 9, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        let choice = InteractiveChoiceDTO(id: 2, cid: 200, option: "下一段")
        let root = node(questions: [.init(duration: 2000, pauseVideo: 0, choices: [choice])])
        let c = InteractiveVideoCoordinator { _, _, edge, _, _ in edge == 0 || edge == 1 ? root : self.node(edge, cid: 200, questions: [], leaf: true) }
        defer { c.reset(); player.replaceCurrentItem(with: nil) }
        c.bind(player: player, item: original, bvid: bv, cid: 100, info: info, allowed: true)
        await drain()
        let installed = expectation(description: "Native branch item installed")
        let restored = expectation(description: "Native rewind seek finished")
        let rootID = try XCTUnwrap(c.history.first?.id)
        c.transition = { cid, resume in
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            c.replaceItemBinding(player: player, item: item)
            try await PlayerItemReadiness.waitUntilReady(item, player: player)
            guard await player.seek(to: CMTime(seconds: Double(resume) / 1000, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero) else {
                throw InteractiveVideoCoordinator.StoryError("Native seek failed")
            }
            if cid == 100 { restored.fulfill() } else { installed.fulfill() }
            return true
        }
        _ = c.handleCompletion(); c.choose(choice)
        await fulfillment(of: [installed], timeout: 5)
        await drain()
        XCTAssertFalse(player.currentItem === original)
        XCTAssertEqual(player.currentTime().seconds, 0, accuracy: 0.05)
        XCTAssertEqual(c.node?.edgeID, 2)
        XCTAssertFalse(c.isBlocking)
        XCTAssertEqual(player.rate, 0)
        c.rewind(to: rootID)
        await fulfillment(of: [restored], timeout: 5)
        await drain()
        XCTAssertEqual(player.currentTime().seconds, 8, accuracy: 0.05)
        XCTAssertEqual(c.node?.edgeID, 1)
        XCTAssertEqual(c.presentation.phase, .choices)
        XCTAssertEqual(c.presentation.secondsRemaining, 2)
    }

    private func ready(_ item: AVPlayerItem) async {
        let ready = expectation(description: "AVPlayerItem ready")
        let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .readyToPlay || item.status == .failed { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 5)
        observation.invalidate()
        XCTAssertEqual(item.status, .readyToPlay, item.error?.localizedDescription ?? "")
    }
}

private final class StoryItem: AVPlayerItem {
    override var duration: CMTime { CMTime(seconds: 100, preferredTimescale: 600) }
}
private final class ReadinessItem: AVPlayerItem {
    private var currentStatus: AVPlayerItem.Status = .unknown
    override var status: AVPlayerItem.Status { currentStatus }
    func publish(_ value: AVPlayerItem.Status) {
        willChangeValue(forKey: "status")
        currentStatus = value
        didChangeValue(forKey: "status")
    }
}
private final class StoryPlayer: AVPlayer {
    var position = 0.0
    var playing = false
    private var boundaries: [UUID: () -> Void] = [:]
    override var rate: Float { get { playing ? 1 : 0 } set { playing = newValue > 0 } }
    override func currentTime() -> CMTime { CMTime(seconds: position, preferredTimescale: 600) }
    override func addBoundaryTimeObserver(forTimes times: [NSValue], queue: DispatchQueue?, using block: @escaping () -> Void) -> Any {
        let id = UUID(); boundaries[id] = block; return id
    }
    override func removeTimeObserver(_ observer: Any) { if let id = observer as? UUID { boundaries[id] = nil } }
    func fireBoundaries() { Array(boundaries.values).forEach { $0() } }
}
