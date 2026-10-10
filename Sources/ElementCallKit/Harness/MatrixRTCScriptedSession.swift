//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Synchronization

/// A media session that plays a scenario instead of a call, and records what the call asks of it.
///
/// It serves the roster and local-state surfaces the way the core does — pushed, latest value
/// wins — and answers everything else with nothing: no audio, no video (frames come from the test
/// pattern through `ElementCallPreviewVideo`), no statistics. What it keeps is every detail window
/// and every constraint the call sends, stamped with the scenario clock, because those are the
/// requests the layout spec is about and nothing else can see them.
///
/// The bindings' types stay inside this module, which is the one allowed to import the core; the
/// records are in the app's own terms.
@available(iOS 18, *)
public final nonisolated class MatrixRTCScriptedSession: MediaSessionProtocol, Sendable {
    public struct DetailWindowRecord: Sendable, Equatable {
        public let time: Duration
        public let offset: Int
        public let length: Int
        public let also: [MatrixRTCTileID]
    }
    
    public struct ConstraintsRecord: Sendable, Equatable {
        public let time: Duration
        public let stream: MatrixRTCStreamRef
        public let constraints: MatrixRTCVideoConstraints
    }
    
    private struct State: Sendable {
        var roster = FfiTileRoster(order: [], detail: [])
        var hasUnreadRoster = false
        var pendingRoster: CheckedContinuation<FfiTileRoster?, Never>?
        var localState: FfiLocalState
        var hasUnreadLocalState = false
        var pendingLocalState: CheckedContinuation<FfiLocalState?, Never>?
        var pendingEvent: CheckedContinuation<FfiCallEvent?, Never>?
        var hasEnded = false
        /// Tiles the next rosters carry detail for; nil for everything.
        var detailOnly: Set<MatrixRTCTileID>?
        var detailWindows: [DetailWindowRecord] = []
        var constraints: [ConstraintsRecord] = []
    }
    
    public let localMemberID: String
    private let state: Mutex<State>
    private let clock: MatrixRTCManualClock
    
    public init(localMemberID: String, clock: MatrixRTCManualClock) {
        self.localMemberID = localMemberID
        self.clock = clock
        state = Mutex(State(localState: Self.localState(memberID: localMemberID, hasVideo: false, isMicrophoneMuted: false)))
    }
    
    // MARK: - Driving
    
    /// The next roster the call sees, built from the tokens as the core would publish them.
    public func push(roster tokens: [MatrixRTCScenario.Token]) {
        let pending = state.withLock { state -> CheckedContinuation<FfiTileRoster?, Never>? in
            let only = state.detailOnly
            state.roster = FfiTileRoster(order: tokens.map(Self.reference),
                                         detail: tokens.filter { only?.contains($0.tileID) ?? true }.map(Self.detail))
            guard let pending = state.pendingRoster else {
                state.hasUnreadRoster = true
                return nil
            }
            state.pendingRoster = nil
            return pending
        }
        pending?.resume(returning: state.withLock { $0.roster })
    }
    
    public func push(me hasVideo: Bool, isMicrophoneMuted: Bool) {
        let pending = state.withLock { state -> CheckedContinuation<FfiLocalState?, Never>? in
            state.localState = Self.localState(memberID: localMemberID, hasVideo: hasVideo, isMicrophoneMuted: isMicrophoneMuted)
            guard let pending = state.pendingLocalState else {
                state.hasUnreadLocalState = true
                return nil
            }
            state.pendingLocalState = nil
            return pending
        }
        pending?.resume(returning: state.withLock { $0.localState })
    }
    
    /// Narrows what the next rosters carry detail for. Nil widens back to everything.
    public func setDetailOnly(_ tiles: Set<MatrixRTCTileID>?) {
        state.withLock { $0.detailOnly = tiles }
    }
    
    public var detailWindows: [DetailWindowRecord] {
        state.withLock { $0.detailWindows }
    }
    
    public var constraints: [ConstraintsRecord] {
        state.withLock { $0.constraints }
    }
    
    /// The last window declared, if any.
    public var detailWindow: DetailWindowRecord? {
        detailWindows.last
    }
    
    /// The last constraints sent for a stream, if any.
    public func lastConstraints(for stream: MatrixRTCStreamRef) -> MatrixRTCVideoConstraints? {
        constraints.last { $0.stream == stream }?.constraints
    }
    
    // MARK: - MediaSessionProtocol: the surfaces
    
    public func nextRoster() async -> FfiTileRoster? {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> FfiTileRoster?? in
                if state.hasUnreadRoster {
                    state.hasUnreadRoster = false
                    return .some(state.roster)
                }
                if state.hasEnded {
                    return .some(nil)
                }
                state.pendingRoster = continuation
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }
    
    public func nextLocalState() async -> FfiLocalState? {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> FfiLocalState?? in
                if state.hasUnreadLocalState {
                    state.hasUnreadLocalState = false
                    return .some(state.localState)
                }
                if state.hasEnded {
                    return .some(nil)
                }
                state.pendingLocalState = continuation
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }
    
    /// Nothing ever happens on the event stream but the end.
    public func nextEvent() async -> FfiCallEvent? {
        await withCheckedContinuation { continuation in
            let ended = state.withLock { state -> Bool in
                if state.hasEnded {
                    return true
                }
                state.pendingEvent = continuation
                return false
            }
            if ended {
                continuation.resume(returning: nil)
            }
        }
    }
    
    public func roster() -> FfiTileRoster {
        state.withLock { $0.roster }
    }
    
    public func localState() -> FfiLocalState? {
        state.withLock { $0.localState }
    }
    
    public func setDetailWindow(offset: UInt32, len: UInt32, also: [FfiTileId]) {
        let record = DetailWindowRecord(time: clock.elapsed, offset: Int(offset), length: Int(len), also: also.map(MatrixRTCTileID.init))
        state.withLock { $0.detailWindows.append(record) }
    }
    
    public func setConstraints(memberId: String, kind: FfiStreamKind, constraints: FfiMediaConstraints) {
        let size: CGSize? = if case .dimensions(let width, let height) = constraints.detail {
            CGSize(width: Double(width), height: Double(height))
        } else {
            nil
        }
        let record = ConstraintsRecord(time: clock.elapsed,
                                       stream: MatrixRTCStreamRef(memberID: memberId, kind: .init(kind)),
                                       constraints: .init(isEnabled: constraints.enabled, isVisible: constraints.visible, pixelSize: size))
        state.withLock { $0.constraints.append(record) }
    }
    
    public func disconnect() async throws {
        let pending = state.withLock { state -> (CheckedContinuation<FfiTileRoster?, Never>?, CheckedContinuation<FfiLocalState?, Never>?, CheckedContinuation<FfiCallEvent?, Never>?) in
            state.hasEnded = true
            defer {
                state.pendingRoster = nil
                state.pendingLocalState = nil
                state.pendingEvent = nil
            }
            return (state.pendingRoster, state.pendingLocalState, state.pendingEvent)
        }
        pending.0?.resume(returning: nil)
        pending.1?.resume(returning: nil)
        pending.2?.resume(returning: nil)
    }
    
    // MARK: - MediaSessionProtocol: inert
    
    public func localIdentity() -> String {
        localMemberID
    }
    
    public func participants() -> [FfiParticipant] {
        []
    }
    
    public func audioStream(memberId: String, kind: FfiStreamKind) -> AudioFrameStream? {
        nil
    }
    
    public func videoStream(memberId: String, kind: FfiStreamKind) -> VideoFrameStream? {
        nil
    }
    
    public func publish(options: FfiPublishOptions) async throws -> FfiLocalTrack {
        FfiLocalTrack(noPointer: .init())
    }
    
    public func unpublish(kind: FfiStreamKind) async throws { }
    public func setLocalMuted(kind: FfiStreamKind, muted: Bool) async throws { }
    
    public func receiveStats(memberId: String, kind: FfiStreamKind) async -> FfiReceiveStats? {
        nil
    }
    
    public func receiveStatsFor(streams: [FfiStreamRef]) async -> [FfiStreamStats] {
        []
    }
    
    // MARK: - Tokens to the bindings' records
    
    private static func reference(_ token: MatrixRTCScenario.Token) -> FfiTileRef {
        FfiTileRef(id: FfiTileId(memberId: token.memberID, kind: token.kind.ffi), userId: token.userID, hero: token.isHero)
    }
    
    private static func detail(_ token: MatrixRTCScenario.Token) -> FfiCallTile {
        FfiCallTile(memberId: token.memberID,
                    kind: token.kind.ffi,
                    userId: token.userID,
                    deviceId: "DEVICE",
                    hero: token.isHero,
                    hasVideo: token.hasVideo,
                    microphoneMuted: token.isMicrophoneMuted,
                    speaking: token.isSpeaking,
                    handRaisedAtMs: token.hasHandRaised ? 1 : nil,
                    reachable: true)
    }
    
    private static func localState(memberID: String, hasVideo: Bool, isMicrophoneMuted: Bool) -> FfiLocalState {
        FfiLocalState(tile: FfiCallTile(memberId: memberID,
                                        kind: .person,
                                        userId: "@me:example.com",
                                        deviceId: "ME",
                                        hero: false,
                                        hasVideo: hasVideo,
                                        microphoneMuted: isMicrophoneMuted,
                                        speaking: false,
                                        handRaisedAtMs: nil,
                                        reachable: true),
                      isScreenSharing: false)
    }
}

/// Walks a call through a scenario: advances the clock to each frame, feeds rosters to the session
/// and waits for the call to have taken them, and hands actions back to whoever drives the stage.
///
/// The player owns the call rather than the other way round because `MatrixRTCCall.init` is
/// internal: this is the one public way to make a call that has no session behind it, and it is
/// public because the example harness runs on it, the same reason `ElementCallFakes` ship.
@available(iOS 18, *)
public final class MatrixRTCScenarioPlayer {
    public let scenario: MatrixRTCScenario
    public let clock: MatrixRTCManualClock
    public let session: MatrixRTCScriptedSession
    public let call: MatrixRTCCall
    /// The index of the next frame `step()` applies.
    public private(set) var position = 0
    
    public var isFinished: Bool {
        position >= scenario.frames.count
    }
    
    public init(scenario: MatrixRTCScenario, localMemberID: String = "@me:example.com:ME") {
        self.scenario = scenario
        clock = MatrixRTCManualClock()
        session = MatrixRTCScriptedSession(localMemberID: localMemberID, clock: clock)
        call = MatrixRTCCall(localMemberID: localMemberID, mediaSession: session, clock: clock, capturesCamera: false)
    }
    
    /// Starts the call's pumps. Nothing has been applied yet; the first `step()` applies frame 0.
    public func start() async {
        await call.start()
    }
    
    /// Applies the next frame and returns it, or nil at the end. The clock is advanced first, so
    /// anything due on the call's own clock — a linger, the stats poll — fires before the frame.
    public func step() async -> MatrixRTCScenario.Frame? {
        guard position < scenario.frames.count else { return nil }
        let frame = scenario.frames[position]
        position += 1
        // A request is stamped when it reaches the session, so the last frame's must land first.
        await settle()
        clock.advance(to: frame.time)
        await settle()
        switch frame.event {
        case .roster(let tokens):
            session.push(roster: tokens)
            await waitUntil { [call] in
                call.tiles.order.map(\.id) == tokens.map(\.tileID)
                    && Set(call.tiles.detail.keys) == Set(tokens.map(\.tileID)).intersection(self.detailOnly ?? Set(tokens.map(\.tileID)))
            }
        case .me(let hasVideo, let isMicrophoneMuted):
            session.push(me: hasVideo, isMicrophoneMuted: isMicrophoneMuted)
            await waitUntil { [call] in
                call.ownTile?.hasVideo == hasVideo && call.ownTile?.isMicrophoneMuted == isMicrophoneMuted
            }
        case .detailOnly(let tiles):
            detailOnly = Set(tiles)
            session.setDetailOnly(detailOnly)
        case .viewport, .scroll, .rotate, .fullscreen, .swipeHero, .minimize, .restore, .tick:
            break
        }
        return frame
    }
    
    /// Lets the main actor run what the last step resumed, then waits for whatever that sent to
    /// reach the session.
    public func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
        await call.drainMediaRequests()
    }
    
    private var detailOnly: Set<MatrixRTCTileID>?
    
    /// Sleeps rather than yields between looks: a yield loop keeps the main actor busy, and the pump
    /// that satisfies the condition needs it.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
