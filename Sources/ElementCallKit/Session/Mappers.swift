//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc

@available(iOS 18, *)
nonisolated extension MatrixRTCStreamKind {
    init(_ kind: FfiStreamKind) {
        switch kind {
        case .microphone: self = .microphone
        case .camera: self = .camera
        case .screenShare: self = .screenShare
        case .screenShareAudio: self = .screenShareAudio
        case .data: self = .data
        }
    }
    
    var ffi: FfiStreamKind {
        switch self {
        case .microphone: .microphone
        case .camera: .camera
        case .screenShare: .screenShare
        case .screenShareAudio: .screenShareAudio
        case .data: .data
        }
    }
}

@available(iOS 18, *)
nonisolated extension MatrixRTCElementCallCompat {
    var ffi: FfiElementCallCompat {
        switch self {
        case .off: .off
        case .stickyEvents: .stickyEvents
        case .stateEvents: .stateEvents
        }
    }
}

@available(iOS 18, *)
nonisolated extension MatrixRTCTransport {
    var ffi: FfiTransportConfig? {
        switch self {
        case .liveKit(let serviceURL): FfiTransportConfig(type: "livekit", livekitServiceUrl: serviceURL.absoluteString)
        case .unsupported: nil
        }
    }
}

@available(iOS 18, *)
nonisolated extension MatrixRTCNotify {
    var ffi: FfiNotifyConfig {
        FfiNotifyConfig(notificationType: kind == .ring ? .ring : .notification,
                        intent: intent.rawValue,
                        lifetimeMs: nil,
                        mentionUserIds: [],
                        mentionRoom: false)
    }
}

@available(iOS 18, *)
nonisolated extension MatrixRTCMembership {
    init(_ membership: JoinedMembership) {
        self.init(memberID: membership.memberId,
                  userID: membership.sender,
                  deviceID: membership.senderDeviceId,
                  application: membership.application)
    }
}

@available(iOS 18, *)
nonisolated extension MatrixRTCParticipant {
    init(_ participant: FfiParticipant) {
        self.init(memberID: participant.memberId,
                  userID: participant.userId,
                  deviceID: participant.deviceId,
                  isLocal: participant.isLocal,
                  isReachable: participant.reachable,
                  streams: participant.streams.map { .init(kind: .init($0.kind), isMuted: $0.muted) },
                  handRaisedAt: participant.handRaisedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }
}

@available(iOS 18, *)
nonisolated extension MatrixRTCTileKind {
    init(_ kind: FfiTileKind) {
        switch kind {
        case .person: self = .person
        case .screenShare: self = .screenShare
        }
    }
    
    var ffi: FfiTileKind {
        switch self {
        case .person: .person
        case .screenShare: .screenShare
        }
    }
}

@available(iOS 18, *)
nonisolated extension MatrixRTCTileID {
    init(_ id: FfiTileId) {
        self.init(memberID: id.memberId, kind: .init(id.kind))
    }
}

@available(iOS 18, *)
nonisolated extension MatrixRTCTile {
    /// `isLocal` is ours to decide: the bindings' tile has no such field, because our own tile only
    /// ever arrives on the local-state surface and is never in the ranked list. Comparing the member
    /// rather than trusting the surface keeps the two answers from disagreeing.
    init(_ tile: FfiCallTile, localMemberID: String) {
        self.init(id: MatrixRTCTileID(memberID: tile.memberId, kind: .init(tile.kind)),
                  userID: tile.userId,
                  deviceID: tile.deviceId,
                  isLocal: tile.memberId == localMemberID,
                  isHero: tile.hero,
                  hasVideo: tile.hasVideo,
                  isMicrophoneMuted: tile.microphoneMuted,
                  isSpeaking: tile.speaking,
                  handRaisedAt: tile.handRaisedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                  isReachable: tile.reachable)
    }
}

@available(iOS 18, *)
nonisolated extension MatrixRTCTileRoster {
    init(_ roster: FfiTileRoster, localMemberID: String) {
        // Keyed by identity on the way in, so nothing downstream is tempted to join by position.
        // The two lists are the same length only while the detail window is the default one.
        var detail = [MatrixRTCTileID: MatrixRTCTile](minimumCapacity: roster.detail.count)
        for tile in roster.detail {
            let mapped = MatrixRTCTile(tile, localMemberID: localMemberID)
            detail[mapped.id] = mapped
        }
        self.init(order: roster.order.map { MatrixRTCTileRef(id: .init($0.id), userID: $0.userId, isHero: $0.hero) },
                  detail: detail)
    }
}

@available(iOS 18, *)
nonisolated extension MatrixRTCLocalState {
    init(_ state: FfiLocalState, localMemberID: String) {
        self.init(tile: MatrixRTCTile(state.tile, localMemberID: localMemberID),
                  isScreenSharing: state.isScreenSharing)
    }
}

@available(iOS 18, *)
nonisolated extension MatrixRTCReceiveStats {
    init(_ stats: FfiReceiveStats) {
        self.init(packetsReceived: stats.packetsReceived,
                  packetsLost: stats.packetsLost,
                  bytesReceived: stats.bytesReceived,
                  jitter: stats.jitter,
                  framesDecoded: stats.framesDecoded,
                  framesDropped: stats.framesDropped,
                  totalSamplesReceived: stats.totalSamplesReceived,
                  concealedSamples: stats.concealedSamples)
    }
}

@available(iOS 18, *)
nonisolated extension MatrixRTCFrameEncryptionState {
    init(_ state: FfiFrameEncryptionState) {
        switch state {
        case .ok: self = .ok
        case .missingKey: self = .missingKey
        case .decryptionFailed: self = .decryptionFailed
        case .encryptionFailed: self = .encryptionFailed
        case .internalError: self = .internalError
        }
    }
}

@available(iOS 18, *)
nonisolated extension MatrixRTCCallEvent {
    init(_ event: FfiCallEvent) {
        switch event {
        case .participantJoined(let memberId, let userId):
            self = .participantJoined(memberID: memberId, userID: userId)
        case .participantLeft(let memberId):
            self = .participantLeft(memberID: memberId)
        case .streamStarted(let memberId, let kind):
            self = .streamStarted(memberID: memberId, kind: .init(kind))
        case .streamStopped(let memberId, let kind):
            self = .streamStopped(memberID: memberId, kind: .init(kind))
        case .streamMuted(let memberId, let kind):
            self = .streamMuted(memberID: memberId, kind: .init(kind))
        case .streamUnmuted(let memberId, let kind):
            self = .streamUnmuted(memberID: memberId, kind: .init(kind))
        case .keyImported(let memberId, let keyIndex):
            self = .keyImported(memberID: memberId, keyIndex: keyIndex)
        case .frameEncryptionState(let memberId, let state, _):
            self = .frameEncryptionState(memberID: memberId, state: .init(state))
        case .keyDiscarded(let memberId, let keyIndex, let senderUserId, let senderDeviceId, let reason):
            self = .keyDiscarded(memberID: memberId,
                                 reason: "index \(keyIndex.map(String.init) ?? "?") from \(senderUserId ?? "?")/\(senderDeviceId ?? "?"): \(reason)")
        case .handRaised(let memberId, let raisedAtMs):
            self = .handRaised(memberID: memberId, raisedAt: Date(timeIntervalSince1970: Double(raisedAtMs) / 1000))
        case .handLowered(let memberId):
            self = .handLowered(memberID: memberId)
        case .reaction(let memberId, let emoji, let name, _):
            self = .reaction(memberID: memberId, emoji: emoji, name: name)
        case .unknownParticipant(let identity):
            // Not surfaced: the transport knows an identity the membership projection doesn't (yet).
            self = .mediaConnectionDegraded(false)
            MatrixRTCLog.debug("Unknown participant on the transport: \(identity)")
        case .mediaConnectionState(let degraded):
            self = .mediaConnectionDegraded(degraded)
        case .ended(let reason):
            switch reason {
            case .left: self = .ended(.left)
            case .connectionClosed(let message): self = .ended(.connectionClosed(message: message))
            }
        }
    }
}
