//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

@available(iOS 18, *)
public nonisolated enum MatrixRTCConstants {
    /// The application every room call uses.
    public static let callApplication = "m.call"
    /// The slot Element Call opens for a room-wide call. MSC4143 requires the `{application}#` prefix.
    public static let roomCallSlotID = "m.call#ROOM"
}

@available(iOS 18, *)
public nonisolated enum MatrixRTCEventTypes {
    /// MSC4143 membership, spec and unstable spellings.
    public static let member = ["m.rtc.member", "org.matrix.msc4143.rtc.member"]
    /// The pre-MSC4354 Element Call membership room state.
    public static let legacyStateMember = "org.matrix.msc3401.call.member"
    /// MSC4143 media key to-device type.
    public static let encryptionKey = "org.matrix.msc4143.rtc.encryption_key"
    /// Element Call's own media key dialect (a `keys` array), sent *instead of* the spec type.
    public static let legacyEncryptionKey = "io.element.call.encryption_keys"
}

@available(iOS 18, *)
public nonisolated enum MatrixRTCStreamKind: Sendable, Hashable {
    case microphone, camera, screenShare, screenShareAudio, data
}

/// What identifies a tile: a member, and whether this is them or a screen they are sharing.
///
/// The member alone was the identity for as long as a member could only be one tile. A member
/// publishing a camera *and* a screen share is two tiles now, drawn at once and ranked separately,
/// so the member alone names a person rather than a tile — and a `Set` keyed on one silently keeps
/// one of the two, which is the failure this type exists to make unrepresentable.
///
/// It is deliberately one type for a tile and the video stream it draws. The bindings have always
/// addressed a stream by exactly this pair — `videoStream(memberId:kind:)`,
/// `setConstraints(memberId:kind:)` — and this layer has always had a private struct for it; they
/// simply never shared a name. Giving them one is what lets the stage hand back something the media
/// layer can act on without having to guess the kind. What it never names is a microphone: a stream
/// that is not a tile is a ``MatrixRTCStreamRef``, the same pair without the "renderable" in it.
@available(iOS 18, *)
public nonisolated struct MatrixRTCTileID: Sendable, Hashable {
    public let memberID: String
    public let kind: MatrixRTCTileKind
    
    public init(memberID: String, kind: MatrixRTCTileKind = .person) {
        self.memberID = memberID
        self.kind = kind
    }
}

/// What a tile is: a person, or a screen they are sharing.
///
/// Not a ``MatrixRTCStreamKind``. A person tile draws the member's camera and carries their
/// microphone state; a share tile draws the screen. Which stream a tile draws is ``videoStreamKind``,
/// so nothing guesses it — and a microphone can never be spelled as a tile.
@available(iOS 18, *)
public nonisolated enum MatrixRTCTileKind: Sendable, Hashable {
    case person, screenShare
    
    /// The stream this kind of tile draws: what the media plane is addressed by.
    public var videoStreamKind: MatrixRTCStreamKind {
        switch self {
        case .person: .camera
        case .screenShare: .screenShare
        }
    }
}

/// One of a member's streams, of any kind: what per-stream statistics are keyed by.
///
/// Not a ``MatrixRTCTileID``, on purpose: a tile is a *renderable* stream, camera or screen share,
/// and this can name a microphone. Build one from a tile with its member and kind.
@available(iOS 18, *)
public nonisolated struct MatrixRTCStreamRef: Sendable, Hashable {
    public let memberID: String
    public let kind: MatrixRTCStreamKind
    
    public init(memberID: String, kind: MatrixRTCStreamKind) {
        self.memberID = memberID
        self.kind = kind
    }
    
    /// The stream a tile draws.
    public init(_ tile: MatrixRTCTileID) {
        self.init(memberID: tile.memberID, kind: tile.kind.videoStreamKind)
    }
    
    /// The tile this stream is drawn on, if it is one: a camera is a person's tile, a screen share
    /// its own. A microphone is nobody's tile.
    public var tileID: MatrixRTCTileID? {
        switch kind {
        case .camera: MatrixRTCTileID(memberID: memberID, kind: .person)
        case .screenShare: MatrixRTCTileID(memberID: memberID, kind: .screenShare)
        default: nil
        }
    }
}

/// How the membership is published, fixed for the lifetime of a session.
@available(iOS 18, *)
public nonisolated enum MatrixRTCElementCallCompat: String, Sendable, CaseIterable, Codable {
    /// MSC4143 as it stands.
    case off
    /// Membership as an MSC4354 sticky event with legacy fields alongside.
    case stickyEvents
    /// `org.matrix.msc3401.call.member` room state and delayed state events; what Element Web speaks today.
    case stateEvents
}

@available(iOS 18, *)
public nonisolated enum MatrixRTCTransport: Sendable, Hashable {
    case liveKit(serviceURL: URL)
    case unsupported(type: String)
}

@available(iOS 18, *)
public nonisolated enum MatrixRTCCallIntent: String, Sendable {
    case audio, video
}

/// MSC4075 notification sent with the membership when *starting* a call.
@available(iOS 18, *)
public nonisolated struct MatrixRTCNotify: Sendable, Hashable {
    public enum Kind: Sendable { case ring, notification }
    
    public let kind: Kind
    public let intent: MatrixRTCCallIntent
    
    public init(kind: Kind, intent: MatrixRTCCallIntent) {
        self.kind = kind
        self.intent = intent
    }
}

@available(iOS 18, *)
public nonisolated struct MatrixRTCLeaveReason: Sendable, Hashable {
    public let code: String
    public let reason: String?
    
    public init(code: String, reason: String? = nil) {
        self.code = code
        self.reason = reason
    }
}

@available(iOS 18, *)
public nonisolated struct MatrixRTCMembership: Sendable, Hashable, Identifiable {
    public let memberID: String
    public let userID: String
    public let deviceID: String?
    public let application: String?
    
    public var id: String {
        memberID
    }
}

@available(iOS 18, *)
public nonisolated struct MatrixRTCStreamState: Sendable, Hashable {
    public let kind: MatrixRTCStreamKind
    public let isMuted: Bool
    
    public init(kind: MatrixRTCStreamKind, isMuted: Bool) {
        self.kind = kind
        self.isMuted = isMuted
    }
}

/// The transport's view of a member; differs legitimately from the membership projection.
@available(iOS 18, *)
public nonisolated struct MatrixRTCParticipant: Sendable, Hashable, Identifiable {
    public let memberID: String
    public let userID: String
    public let deviceID: String?
    public let isLocal: Bool
    public let isReachable: Bool
    public let streams: [MatrixRTCStreamState]
    public let handRaisedAt: Date?
    
    public init(memberID: String, userID: String, deviceID: String?, isLocal: Bool, isReachable: Bool, streams: [MatrixRTCStreamState], handRaisedAt: Date?) {
        self.memberID = memberID
        self.userID = userID
        self.deviceID = deviceID
        self.isLocal = isLocal
        self.isReachable = isReachable
        self.streams = streams
        self.handRaisedAt = handRaisedAt
    }
    
    public var id: String {
        memberID
    }
    
    public func stream(_ kind: MatrixRTCStreamKind) -> MatrixRTCStreamState? {
        streams.first { $0.kind == kind }
    }
    
    public func isPublishing(_ kind: MatrixRTCStreamKind) -> Bool {
        stream(kind).map { !$0.isMuted } ?? false
    }
}

/// One renderable stream of one membership, as the model ranked it.
///
/// A tile rather than a participant, and the difference is the point: a member publishing a camera
/// and a screen share is **two** tiles, drawn at the same time and ranked separately. The model
/// derives these from the roster, orders them, and damps the order; the app renders them in the
/// order given. Re-sorting here would fight damping the model has already applied, at a different
/// period, and make the strip twitch on every word.
@available(iOS 18, *)
public nonisolated struct MatrixRTCTile: Sendable, Hashable, Identifiable {
    public let id: MatrixRTCTileID
    public let userID: String
    public let deviceID: String?
    /// Ourselves. Not the model's — our own tile arrives on its own surface and is never in the
    /// ranked list — but the layout needs it, because the thumbnail and "You" are facts about
    /// *whose* tile this is rather than about the stream.
    public let isLocal: Bool
    /// The model marks the tile worth the largest slot: a screen share today, a pin later. It does
    /// **not** choose a spotlight — what a UI does with its largest slot stays the UI's business.
    public let isHero: Bool
    /// This tile's own stream is present and unmuted. Collapses "no camera" and "camera paused",
    /// because both draw an avatar. On a share tile it is the share.
    public let hasVideo: Bool
    /// The *member's* microphone is absent or muted — what a mute icon means. Named for its subject
    /// because a tile is itself a stream that can be muted, and that state is ``hasVideo``.
    public let isMicrophoneMuted: Bool
    public let isSpeaking: Bool
    public let handRaisedAt: Date?
    public let isReachable: Bool
    
    public var memberID: String {
        id.memberID
    }
    
    public var kind: MatrixRTCTileKind {
        id.kind
    }
    
    public var isScreenShare: Bool {
        id.kind == .screenShare
    }
    
    public init(id: MatrixRTCTileID,
                userID: String,
                deviceID: String? = nil,
                isLocal: Bool = false,
                isHero: Bool = false,
                hasVideo: Bool = false,
                isMicrophoneMuted: Bool = false,
                isSpeaking: Bool = false,
                handRaisedAt: Date? = nil,
                isReachable: Bool = true) {
        self.id = id
        self.userID = userID
        self.deviceID = deviceID
        self.isLocal = isLocal
        self.isHero = isHero
        self.hasVideo = hasVideo
        self.isMicrophoneMuted = isMicrophoneMuted
        self.isSpeaking = isSpeaking
        self.handRaisedAt = handRaisedAt
        self.isReachable = isReachable
    }
}

/// A tile's place in the ranking: what it is, whose it is, and whether it is a hero — and nothing
/// about what the member is doing.
///
/// One of these exists for **every** tile in the call, always — the order is never truncated — so
/// the set a UI is *not* drawing is computable from it, which is what drives releasing subscriptions.
/// Detail arrives only for the tiles inside the declared window, which is everything by default; a
/// tile outside it still has ``userID``, which is what a name and an avatar resolve through, so it
/// draws as an avatar tile rather than an empty one.
@available(iOS 18, *)
public nonisolated struct MatrixRTCTileRef: Sendable, Hashable {
    public let id: MatrixRTCTileID
    public let userID: String
    public let isHero: Bool
    
    public init(id: MatrixRTCTileID, userID: String, isHero: Bool = false) {
        self.id = id
        self.userID = userID
        self.isHero = isHero
    }
}

/// The model's ranking, and the detail we asked for.
@available(iOS 18, *)
public nonisolated struct MatrixRTCTileRoster: Sendable, Equatable {
    /// Every tile in the call, in rank order: hero, then hand raised earliest first, then speaking,
    /// then video, then join time. **Render in this order. Never re-sort it.**
    public let order: [MatrixRTCTileRef]
    /// Joined to ``order`` **by identity, never by index**. A dictionary rather than an array for
    /// exactly that reason: the two are the same length only while the detail window is the default
    /// one, and joining by position is a silent wrong answer rather than a crash the day it is not.
    public let detail: [MatrixRTCTileID: MatrixRTCTile]
    
    public init(order: [MatrixRTCTileRef], detail: [MatrixRTCTileID: MatrixRTCTile]) {
        self.order = order
        self.detail = detail
    }
    
    /// Every tile in the order, with detail for all of them. What the default window produces, and
    /// the shape a test or a fixture wants.
    public init(_ tiles: [MatrixRTCTile]) {
        self.init(order: tiles.map { MatrixRTCTileRef(id: $0.id, userID: $0.userID, isHero: $0.isHero) },
                  detail: Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, $0) }))
    }
    
    public static let empty = MatrixRTCTileRoster(order: [], detail: [:])
    
    public subscript(id: MatrixRTCTileID) -> MatrixRTCTile? {
        detail[id]
    }
    
    /// The ranked tiles we hold detail for, in order. The accessor a renderer should use: when the
    /// window narrows this shortens rather than producing half-built tiles.
    public var ranked: [MatrixRTCTile] {
        order.compactMap { detail[$0.id] }
    }
}

/// What a consumer asks the model for full records of: a rank range over the remote order, plus
/// the tiles it draws out of rank order (002 contract C12). Everything else arrives as a
/// reference, which is enough to draw a name and an avatar. The default, detail for everything,
/// costs the whole call on every update at two hundred participants.
@available(iOS 18, *)
public nonisolated struct MatrixRTCDetailWindow: Sendable, Equatable {
    /// Half-open, over ``MatrixRTCTileRoster/order``. Clamped by the core; asking past the end is
    /// not an error.
    public var ranks: Range<Int>
    /// Included wherever they rank: the spotlight, a fullscreen tile, the Picture in Picture tile.
    /// Identities not in the call are ignored, not errors.
    public var also: Set<MatrixRTCTileID>
    
    public init(ranks: Range<Int>, also: Set<MatrixRTCTileID> = []) {
        self.ranks = ranks
        self.also = also
    }
    
    public static let none = MatrixRTCDetailWindow(ranks: 0..<0)
}

/// What is true of *us*, beside the roster rather than in it, and changing when we act rather than
/// when the call moves.
@available(iOS 18, *)
public nonisolated struct MatrixRTCLocalState: Sendable, Equatable {
    /// Our own tile. Never in the ranked list, and never a hero.
    public let tile: MatrixRTCTile
    /// Derived from publication state — the stream up *and* unmuted — never from what we asked for,
    /// so it goes false however the share ended.
    public let isScreenSharing: Bool
    
    public init(tile: MatrixRTCTile, isScreenSharing: Bool) {
        self.tile = tile
        self.isScreenSharing = isScreenSharing
    }
}

@available(iOS 18, *)
public nonisolated enum MatrixRTCFrameEncryptionState: Sendable, Hashable {
    case ok, missingKey, decryptionFailed, encryptionFailed, internalError
}

@available(iOS 18, *)
public nonisolated enum MatrixRTCEndReason: Sendable, Hashable {
    case left
    case connectionClosed(message: String)
}

@available(iOS 18, *)
public nonisolated enum MatrixRTCCallEvent: Sendable, Hashable {
    case participantJoined(memberID: String, userID: String)
    case participantLeft(memberID: String)
    case streamStarted(memberID: String, kind: MatrixRTCStreamKind)
    case streamStopped(memberID: String, kind: MatrixRTCStreamKind)
    case streamMuted(memberID: String, kind: MatrixRTCStreamKind)
    case streamUnmuted(memberID: String, kind: MatrixRTCStreamKind)
    case keyImported(memberID: String, keyIndex: UInt8)
    case keyDiscarded(memberID: String, reason: String)
    case frameEncryptionState(memberID: String, state: MatrixRTCFrameEncryptionState)
    case handRaised(memberID: String, raisedAt: Date)
    case handLowered(memberID: String)
    case reaction(memberID: String, emoji: String, name: String)
    case mediaConnectionDegraded(Bool)
    case ended(MatrixRTCEndReason)
}

/// Cumulative receive counters for one stream; sample twice and diff.
@available(iOS 18, *)
public nonisolated struct MatrixRTCReceiveStats: Sendable, Hashable {
    public let packetsReceived: UInt64
    public let packetsLost: Int64
    public let bytesReceived: UInt64
    public let jitter: Double
    public let framesDecoded: UInt64
    public let framesDropped: UInt64
    public let totalSamplesReceived: UInt64
    public let concealedSamples: UInt64
    
    /// Concealment rising in step with samples received means the silence being played is fabricated.
    public var concealedFraction: Float? {
        totalSamplesReceived > 0 ? Float(concealedSamples) / Float(totalSamplesReceived) : nil
    }
}

@available(iOS 18, *)
public nonisolated struct MatrixRTCAudioLevel: Sendable, Hashable {
    /// RMS of the decoded (or captured) PCM, 0...1.
    public let level: Float
    public let frameCount: UInt64
    /// Playback under-runs reported by the audio device, when known.
    public let underrunCount: Int?
}

/// What is arriving (or being captured) on a video stream: upright size and measured frame rate.
@available(iOS 18, *)
public nonisolated struct MatrixRTCVideoInfo: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    
    public var aspect: CGFloat {
        CGFloat(width) / CGFloat(max(1, height))
    }
    
    public init(width: Int, height: Int, framesPerSecond: Int) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
    }
}

/// What a tile actually draws, so the SFU sends only the layer that fits.
@available(iOS 18, *)
public nonisolated struct MatrixRTCVideoConstraints: Sendable, Hashable {
    /// Whether we are subscribed at all. The core draws a firm line between the two ways of not
    /// wanting a picture, and so do we: `isVisible == false` pauses a stream that is about to come
    /// back, and resumes instantly; `isEnabled == false` releases it as fully as the transport
    /// allows, which is the only one that stops a big call from holding a subscription per member.
    /// Pausing something that will not be looked at again for minutes wastes a subscription;
    /// releasing something a swipe is about to reveal costs a visible re-negotiation.
    public let isEnabled: Bool
    public let isVisible: Bool
    /// The drawn size in pixels, nil to let the SFU pick.
    public let pixelSize: CGSize?
    
    public init(isEnabled: Bool = true, isVisible: Bool, pixelSize: CGSize?) {
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.pixelSize = pixelSize
    }
}

@available(iOS 18, *)
public nonisolated struct MatrixRTCOpenIDToken: Sendable {
    public let accessToken: String
    public let tokenType: String
    public let matrixServerName: String
    public let expiresIn: TimeInterval
    
    public init(accessToken: String, tokenType: String, matrixServerName: String, expiresIn: TimeInterval) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.matrixServerName = matrixServerName
        self.expiresIn = expiresIn
    }
}

@available(iOS 18, *)
public nonisolated enum MatrixRTCError: Error, Sendable {
    case notStarted
    case alreadyJoined(roomID: String)
    case notJoined
    case noLiveKitTransport
    case malformedSlotID(String)
    case ffi(String)
    case media(String)
    /// The host could not set up its Matrix side for the room.
    case transport(String)
}
