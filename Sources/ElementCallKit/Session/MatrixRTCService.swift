//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Synchronization

/// One per Matrix session, created when the session exists rather than when a call starts: media
/// keys arrive over to-device and cannot be caught up on, and the core is meant to notice calls.
///
/// Never rebuilt: it accumulates memberships and keys across calls.
@MainActor
@available(iOS 18, *)
public final class MatrixRTCService {
    private let transport: ElementCallMatrixTransportProtocol
    private var manager: RtcSessionManagerHandle?
    private var keyFeeder: SessionKeyFeeder?
    private var startTask: Task<RtcSessionManagerHandle, Never>?
    private var sessions = [String: MatrixRTCSession]()
    
    public init(transport: ElementCallMatrixTransportProtocol) {
        self.transport = transport
    }
    
    /// Idempotent. Also called from `joinSession`, so a caller that forgets still gets a working call —
    /// one that may have missed keys.
    @discardableResult
    public func start() async -> RtcSessionManagerHandle {
        if let manager {
            return manager
        }
        if let startTask {
            return await startTask.value
        }
        
        let task = Task { [transport] in
            // Logging must be installed by the host before this point; the core is silent otherwise.
            let manager = RtcSessionManagerHandle()
            do {
                try await manager.setCommandSender(callback: MatrixRTCCommandSender(transport: transport))
            } catch {
                MatrixRTCLog.error("Failed setting the command sender: \(error)")
            }
            return manager
        }
        startTask = task
        let manager = await task.value
        self.manager = manager
        
        let keyFeeder = SessionKeyFeeder(manager: manager, transport: transport)
        keyFeeder.start()
        self.keyFeeder = keyFeeder
        MatrixRTCLog.info("Core started for \(transport.userID)")
        return manager
    }
    
    public func stop() {
        keyFeeder?.stop()
        keyFeeder = nil
    }
    
    /// Joins the slot: feeds room members and encryption first, joins, then subscribes and feeds memberships.
    public func joinSession(roomID: String,
                            slotID: String = MatrixRTCConstants.roomCallSlotID,
                            application: String = MatrixRTCConstants.callApplication,
                            transport liveKit: MatrixRTCTransport,
                            compat: MatrixRTCElementCallCompat,
                            notify: MatrixRTCNotify?) async throws -> MatrixRTCSession {
        if let existing = sessions[roomID] {
            throw MatrixRTCError.alreadyJoined(roomID: existing.roomID)
        }
        let manager = await start()
        
        // Nothing enforces this on the way in, and a malformed slot id looks healthy from our side
        // while a conformant peer refuses the membership on sight.
        if !slotID.hasPrefix("\(application)#") {
            MatrixRTCLog.warning("Slot id '\(slotID)' does not start with '\(application)#'; conformant peers will refuse the membership")
        }
        
        MatrixRTCLog.info("Joining \(roomID)/\(slotID) with Element Call compatibility \(compat)")
        
        do {
            try await transport.willJoinRoom(roomID: roomID)
        } catch {
            MatrixRTCLog.error("The transport could not prepare \(roomID): \(error)")
            throw MatrixRTCError.transport("\(error)")
        }
        
        // Weak box so the feeder can report counts before the session object exists.
        let countSink = MemberCountSink()
        let feeder = RoomStateFeeder(manager: manager,
                                     transport: transport,
                                     roomID: roomID,
                                     slotID: slotID,
                                     compat: compat,
                                     onMemberCount: { count in countSink.report(count) })
        feeder.start()
        do {
            try await feeder.awaitRoomMembers()
            try Task.checkCancellation()
        } catch {
            feeder.stop()
            await transport.didLeaveRoom(roomID: roomID)
            throw error
        }
        
        let memberID: String
        do {
            memberID = try await manager.join(params: FfiJoinSessionParams(userId: transport.userID,
                                                                           deviceId: transport.deviceID,
                                                                           roomId: roomID,
                                                                           slotId: slotID,
                                                                           application: application,
                                                                           transport: liveKit.ffi,
                                                                           canSubscribe: ["livekit"],
                                                                           keepAliveTimeoutMs: 20000,
                                                                           stickyDurationMs: nil, // The core owns the membership lifetime.
                                                                           encryptionConfig: nil, // Follow whatever the slot prescribes.
                                                                           elementCallCompat: compat.ffi,
                                                                           notify: notify?.ffi))
        } catch {
            feeder.stop()
            await transport.didLeaveRoom(roomID: roomID)
            MatrixRTCLog.error("Join failed for \(roomID)/\(slotID): \(error)")
            throw MatrixRTCError.ffi("\(error)")
        }
        MatrixRTCLog.info("Joined \(roomID)/\(slotID) as \(memberID)")
        
        let session = MatrixRTCSession(roomID: roomID,
                                       slotID: slotID,
                                       localMemberID: memberID,
                                       manager: manager,
                                       transport: transport,
                                       feeder: feeder)
        countSink.attach(session)
        sessions[roomID] = session
        await session.start()
        return session
    }
    
    /// Forgets a session once it has left; call after `MatrixRTCSession.leave()`.
    public func release(roomID: String) async {
        sessions[roomID] = nil
        await transport.didLeaveRoom(roomID: roomID)
    }
    
    public func debugSnapshot() async -> String {
        guard let manager else { return "core not started" }
        return await (try? manager.debugSnapshot()) ?? "unavailable"
    }
}

/// Bridges the feeder's background count reports onto the main-actor session.
@available(iOS 18, *)
private final nonisolated class MemberCountSink: Sendable {
    private let session: Mutex<MatrixRTCSession?> = .init(nil)
    private let pending: Mutex<Int?> = .init(nil)
    
    func attach(_ session: MatrixRTCSession) {
        self.session.withLock { $0 = session }
        if let count = pending.withLock({ $0 }) {
            report(count)
        }
    }
    
    func report(_ count: Int) {
        guard let session = session.withLock({ $0 }) else {
            pending.withLock { $0 = count }
            return
        }
        Task { @MainActor in session.setMemberCount(count) }
    }
}
