//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Observation

/// A joined MatrixRTC session: membership in, media attached separately.
///
/// Membership and media are separate steps. You are in the call as soon as `join` returned; media
/// is attached with `connectMedia`. Teardown order matters: disconnect media → close the membership
/// subscription → cancel feeds → leave.
@MainActor
@Observable
@available(iOS 18, *)
public final class MatrixRTCSession {
    public let roomID: String
    public let slotID: String
    /// Minted by the core at join time; what every event, roster entry and key report is keyed by.
    public let localMemberID: String
    
    /// Identities from the core's membership projection (who is in the call).
    public private(set) var members: [MatrixRTCMembership] = []
    /// The core's own count, right whenever read; the projection above can lag in some compat modes.
    public private(set) var memberCount = 0
    public private(set) var call: MatrixRTCCall?
    
    private let manager: RtcSessionManagerHandle
    private let transport: ElementCallMatrixTransportProtocol
    private let feeder: RoomStateFeeder
    private var hasLeft = false
    
    @ObservationIgnored private var membershipSubscription: MembershipSnapshotSubscription?
    @ObservationIgnored private var membershipPoller: Task<Void, Never>?
    
    init(roomID: String,
         slotID: String,
         localMemberID: String,
         manager: RtcSessionManagerHandle,
         transport: ElementCallMatrixTransportProtocol,
         feeder: RoomStateFeeder) {
        self.roomID = roomID
        self.slotID = slotID
        self.localMemberID = localMemberID
        self.manager = manager
        self.transport = transport
        self.feeder = feeder
    }
    
    func setMemberCount(_ count: Int) {
        // The screen's projection reads this on every pass, so an unchanged report must not wake it.
        // The core's count is re-queried after every room-state feed and usually comes back the same.
        guard count != memberCount else { return }
        memberCount = count
    }
    
    /// Subscribes to membership snapshots, then starts the membership feed — in that order, because
    /// `nextSnapshot()` only reports what changes *after* the subscription exists.
    func start() async {
        do {
            membershipSubscription = try await manager.subscribeMembershipSnapshots(roomId: roomID, slotId: slotID)
        } catch {
            MatrixRTCLog.warning("Cannot subscribe to memberships for \(roomID)/\(slotID): \(error)")
        }
        
        if let membershipSubscription {
            // A non-blocking poll on iOS: read after each change would be ideal, a 1 s tick is close enough.
            membershipPoller = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        if let snapshot = try membershipSubscription.nextSnapshot() {
                            let members = snapshot.map(MatrixRTCMembership.init)
                            self?.updateMembers(members)
                        }
                    } catch {
                        MatrixRTCLog.warning("Membership subscription for \(self?.roomID ?? "?") ended: \(error)")
                        break
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } else {
            MatrixRTCLog.warning("No membership subscription for \(roomID)/\(slotID), the roster will not update")
        }
        
        feeder.startMemberships()
    }
    
    /// Attaches media. The core knows which membership this session joined as, so no member ID is passed.
    public func connectMedia(transport liveKit: MatrixRTCTransport) async throws -> MatrixRTCCall {
        if let call {
            return call
        }
        guard case .liveKit(let serviceURL) = liveKit else { throw MatrixRTCError.noLiveKitTransport }
        
        let mediaSession: MediaSession
        do {
            mediaSession = try await connectMediaSession(manager: manager,
                                                         config: MediaSessionConfig(roomId: roomID,
                                                                                    slotId: slotID,
                                                                                    userId: transport.userID,
                                                                                    deviceId: transport.deviceID,
                                                                                    livekitServiceUrl: serviceURL.absoluteString),
                                                         tokenProvider: OpenIDTokenProviderAdapter(transport: transport))
        } catch {
            MatrixRTCLog.warning("Failed to connect media for \(roomID)/\(slotID): \(error)")
            throw MatrixRTCError.media("\(error)")
        }
        
        let call = MatrixRTCCall(localMemberID: localMemberID, mediaSession: mediaSession)
        self.call = call
        await call.start()
        MatrixRTCLog.info("Media connected for \(roomID)/\(slotID) as \(localMemberID)")
        return call
    }
    
    /// Idempotent: hanging up and tearing the screen down both leave, and the core rejects a second attempt.
    public func leave(reason: MatrixRTCLeaveReason? = nil) async {
        guard !hasLeft else {
            MatrixRTCLog.debug("Already left \(roomID)/\(slotID)")
            return
        }
        hasLeft = true
        
        await call?.disconnect()
        call = nil
        // Before the leave: a snapshot arriving mid-leave makes the core create a fresh, unseeded session.
        membershipPoller?.cancel()
        membershipSubscription = nil
        feeder.stop()
        
        do {
            let leaveReason = reason.map { FfiLeaveReason(code: $0.code, reason: $0.reason) }
            try await manager.leave(roomId: roomID, slotId: slotID, params: FfiLeaveSessionParams(leaveReason: leaveReason))
            MatrixRTCLog.info("Left \(roomID)/\(slotID)")
        } catch {
            MatrixRTCLog.warning("Failed to leave \(roomID)/\(slotID): \(error)")
        }
    }
    
    private func updateMembers(_ members: [MatrixRTCMembership]) {
        if members.map(\.memberID) != self.members.map(\.memberID) {
            MatrixRTCLog.info("\(members.count) member(s) in \(roomID)/\(slotID): \(members.map(\.memberID))")
        }
        self.members = members
    }
}

@available(iOS 18, *)
private final nonisolated class OpenIDTokenProviderAdapter: OpenIdTokenProvider, Sendable {
    private let transport: ElementCallMatrixTransportProtocol
    
    init(transport: ElementCallMatrixTransportProtocol) {
        self.transport = transport
    }
    
    func getOpenIdToken() async throws -> FfiOpenIdToken {
        do {
            let token = try await transport.requestOpenIDToken()
            return FfiOpenIdToken(accessToken: token.accessToken,
                                  tokenType: token.tokenType,
                                  matrixServerName: token.matrixServerName,
                                  expiresInSecs: UInt64(max(0, token.expiresIn)))
        } catch {
            throw MediaFfiError.Token("OpenID token request failed: \(error)")
        }
    }
}
