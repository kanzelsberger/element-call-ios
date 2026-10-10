//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import Foundation

/// Host settings the call reads. Named Options rather than Configuration because hosts embedding the
/// Element Call widget already have a configuration type of their own.
///
/// A value rather than a protocol, because every member is data a host simply states. Each is read
/// at a discrete moment — compat when a session joins, the Picture in Picture flags when the window
/// binds, developer mode when a toggle is tapped — never per frame, so a live pull has nothing to
/// win. This *was* a protocol of computed properties, on the theory that a host backing it with
/// settings would want a change seen mid-session. No read path ever needed that, and the one host
/// member that was settings-backed could not change while a stack lived, because the same flag
/// decided whether the stack existed. If a live value is genuinely wanted one day, the controller's
/// `options` can gain a setter without breaking anyone; shipping one before there is a caller would
/// only invite a host to wire a publisher to a value read once at join.
///
/// Adding a member is source-compatible as long as its initialiser parameter is defaulted. That is
/// the mechanism to reach for — not a protocol extension supplying a default, which is what this
/// needed while it was a protocol and which hid the addition from every host.
public nonisolated struct ElementCallOptions: Sendable {
    /// Whether a minimized call may open a Picture in Picture window. A host without the
    /// background mode entitlement should set this false, and calls minimize to the bar instead.
    public var isPictureInPictureEnabled: Bool
    /// How membership is published. Pinned by the host because it has to match the other clients in
    /// the room, and it cannot change once a session has joined.
    public var elementCallCompatibility: MatrixRTCElementCallCompat
    /// Whether the call screen offers its developer affordances, currently the per-tile stats
    /// overlay. That is raw RTP counters in 9pt monospace, so this belongs on whatever a host
    /// already uses to reveal developer surface, never on a feature flag ordinary users carry.
    ///
    /// Deliberately not what gates screen sharing: a host may well want to ship that to everyone
    /// while keeping diagnostics to itself, so the two are separate axes.
    public var isDeveloperModeEnabled: Bool
    /// Whether *this* user may start sharing their screen. Receiving someone else's share is never
    /// affected — a remote share still takes the spotlight and renders — because a call with a Web
    /// peer presenting would otherwise look broken.
    ///
    /// The same kind of question as ``isPictureInPictureEnabled`` — the package supporting a feature
    /// is not enough, the host has work of its own — but the opposite default, because that work is
    /// not done yet. Off until a host opts in, rather than on and half-wired.
    public var isScreenSharingEnabled: Bool
    /// Whether *leaving the app* during an audio-only call may open the window by itself. A video
    /// call always may.
    ///
    /// Separate from ``isPictureInPictureEnabled``, which governs minimizing on purpose. The
    /// default is false because CallKit's island already represents a backgrounded audio call, and
    /// a window appearing on every app switch is intrusive when there is only an avatar to show.
    public var isAutomaticPictureInPictureForAudioCallsEnabled: Bool
    
    public init(isPictureInPictureEnabled: Bool = true,
                elementCallCompatibility: MatrixRTCElementCallCompat = .stateEvents,
                isDeveloperModeEnabled: Bool = false,
                isScreenSharingEnabled: Bool = false,
                isAutomaticPictureInPictureForAudioCallsEnabled: Bool = false) {
        self.isPictureInPictureEnabled = isPictureInPictureEnabled
        self.elementCallCompatibility = elementCallCompatibility
        self.isDeveloperModeEnabled = isDeveloperModeEnabled
        self.isScreenSharingEnabled = isScreenSharingEnabled
        self.isAutomaticPictureInPictureForAudioCallsEnabled = isAutomaticPictureInPictureForAudioCallsEnabled
    }
}

/// Text the call screen shows. English defaults, because a host without translations should still
/// get something readable rather than a key.
public nonisolated struct ElementCallStrings: Sendable {
    public var you: String
    public var error: String
    public var stop: String
    public var back: String
    
    public init(you: String = "You", error: String = "Error", stop: String = "Stop", back: String = "Back") {
        self.you = you
        self.error = error
        self.stop = stop
        self.back = back
    }
}
