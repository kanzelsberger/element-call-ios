//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Observation
import Synchronization
import UIKit

/// The media half of a session: publishes the microphone, camera and screen, plays every remote
/// member and hands out video frames for tiles. Owned by `MatrixRTCSession`.
@MainActor
@Observable
@available(iOS 18, *)
public final class MatrixRTCCall {
    public let localMemberID: String
    
    /// The transport's roster (not the membership projection; the two can legitimately differ).
    ///
    /// Kept beside ``tiles`` rather than replaced by it. Tiles are a projection of this, and the
    /// questions that are about the *call* rather than about what is drawn — is anyone on video,
    /// what should a single-tile surface show, what did the transport actually report for a member —
    /// are still answered here, un-joined and one row per membership.
    public private(set) var participants: [MatrixRTCParticipant] = []
    /// What to draw, in the order to draw it. See ``MatrixRTCTileRoster``.
    public private(set) var tiles: MatrixRTCTileRoster = .empty
    /// Our own tile and whether we are sharing our screen; nil until our membership reaches the
    /// roster. Prefer ``ownTile``, which covers that gap.
    public private(set) var localState: MatrixRTCLocalState?
    
    /// Our own tile — and the reason this is not simply `localState?.tile`.
    ///
    /// The model publishes local state only once our membership has reached the roster, a moment or
    /// two after the call connects, and the self view is usually the only picture on screen for that
    /// moment. Waiting for it would flash an empty stage on every single join. The transport roster
    /// already has us by then — `start()` sweeps it synchronously — so the same tile is built from
    /// there until the model publishes its own.
    ///
    /// It also keeps "no tiles" meaning "not connected yet". The ranked list is empty when you are
    /// the only person in the call, and a UI that read emptiness as "nothing to show" would put a
    /// loading spinner over a live call with no way out of it.
    public var ownTile: MatrixRTCTile? {
        if let tile = localState?.tile {
            return tile
        }
        guard let local = participants.first(where: \.isLocal) else { return nil }
        return MatrixRTCTile(id: MatrixRTCTileID(memberID: local.memberID, kind: .person),
                             userID: local.userID,
                             deviceID: local.deviceID,
                             isLocal: true,
                             isHero: false,
                             hasVideo: local.isPublishing(.camera),
                             isMicrophoneMuted: !local.isPublishing(.microphone),
                             isSpeaking: false,
                             handRaisedAt: local.handRaisedAt,
                             isReachable: local.isReachable)
    }
    
    public private(set) var audioLevels: [String: MatrixRTCAudioLevel] = [:]
    /// RTP receive counters per remote stream: each composed tile's own, and its member's microphone.
    /// A stream missing here is not yet reported rather than receiving nothing; a stream nobody draws
    /// is not polled at all.
    public private(set) var receiveStats: [MatrixRTCStreamRef: MatrixRTCReceiveStats] = [:]
    public private(set) var frameEncryption: [String: MatrixRTCFrameEncryptionState] = [:]
    public private(set) var isMicrophoneMuted = false
    public private(set) var isCameraEnabled = false
    /// The system holds the camera (app backgrounded without the multitasking entitlement); the
    /// track is muted at the transport meanwhile so peers see camera-off rather than a frozen frame.
    public private(set) var isCameraInterrupted = false
    public private(set) var isFrontCamera = true
    /// Whether a screen share is actually up.
    ///
    /// The core's answer, derived from publication state — the stream up *and* unmuted — rather than
    /// from what we asked for. That is the point of it: our intent can be wrong, and a share that
    /// failed to come up used to leave this true for the rest of the call.
    ///
    /// ``pendingScreenShare`` is the exception, and it is not a nicety. We publish, start capture,
    /// and unmute only once capture is live (`setScreenShareEnabled`), so between the tap and the
    /// unmute the core is correctly saying *false* — through a second or more of publishing and a
    /// system consent prompt. A banner that appears a second after the button reads as a broken
    /// button. The intent is dropped the instant the core agrees, and on a deadline if it never
    /// does, so it can only ever shorten the truth, never outlive it.
    public var isScreenSharing: Bool {
        pendingScreenShare ?? localState?.isScreenSharing ?? false
    }
    
    private var pendingScreenShare: Bool?
    @ObservationIgnored private var screenShareIntentDeadline: Task<Void, Never>?
    private static let screenShareIntentTimeout = Duration.seconds(10)
    public private(set) var isMediaDegraded = false
    public private(set) var hasEnded = false
    
    /// Every core event, after the call itself reacted to it.
    public let events: AsyncStream<MatrixRTCCallEvent>
    private let eventsContinuation: AsyncStream<MatrixRTCCallEvent>.Continuation
    
    /// The bindings' own protocol rather than the concrete `MediaSession`, so a test can see what
    /// actually reaches the transport -- which is the only place the publish options are observable.
    private let mediaSession: any MediaSessionProtocol
    /// Constraints and windows go to the session off the main actor, since the core may block, and
    /// in order: a queue rather than a detached task, because two requests for one stream a frame
    /// apart must not arrive swapped, or the stale one sticks.
    private let mediaRequests = DispatchQueue(label: "io.element.call.media-requests", qos: .utility)
    private let audioEngine = CallAudioEngine()
    @ObservationIgnored private lazy var microphone = MicrophoneCapturer(engine: audioEngine) { [weak self] level in
        Task { @MainActor in self?.setAudioLevel(level, for: self?.localMemberID) }
    }
    
    @ObservationIgnored private lazy var camera: CameraCapturer = {
        let capturer = CameraCapturer { [weak self] frame in
            guard let self else { return }
            localVideo.offer(frame)
            if let info = localVideoMeter.record(frame) {
                Task { @MainActor in self.videoInfos[MatrixRTCStreamRef(memberID: self.localMemberID, kind: .camera)] = info }
            }
        }
        capturer.onInterruption = { [weak self] interrupted in
            Task { @MainActor in await self?.handleCameraInterruption(interrupted) }
        }
        return capturer
    }()
    
    /// Lazy so the handler can capture `self`, the way the camera capturer above does.
    @ObservationIgnored private lazy var screenShare: ScreenShareCapturer = {
        let capturer = ScreenShareCapturer()
        capturer.setOnUnexpectedStop { [weak self] in
            Task { @MainActor in await self?.handleScreenShareStopped() }
        }
        return capturer
    }()
    
    /// The self view: frames straight from the camera, mirrored for the front one.
    public let localVideo = LocalVideoFanOut()
    
    private var microphoneTrack: FfiLocalTrack?
    private let localVideoMeter = VideoFrameMeter()
    private var cameraTrack: FfiLocalTrack?
    private var playbackSinks = [String: AudioPlaybackSink]()
    private var membersWithoutMicrophone = Set<String>()
    private var videoSources = [MatrixRTCStreamRef: RemoteVideoSource]()
    private var appliedConstraints = [MatrixRTCStreamRef: MatrixRTCVideoConstraints]()
    private var appliedDetailWindow: MatrixRTCDetailWindow?
    /// Streams that are released rather than merely paused. Held per stream rather than per member
    /// because a member can be two tiles: scrolling a sharer's camera away must not take the screen
    /// share filling the spotlight with it, which is exactly what walking both kinds per member did.
    private var releasedVideoStreams = Set<MatrixRTCTileID>()
    /// Streams the stage has composed but is not showing: within a scroll of the screen, so kept
    /// subscribed but not sent, and never released by the linger (003 R56, R58).
    private var pausedVideoStreams = Set<MatrixRTCTileID>()
    private var tasks = [Task<Void, Never>]()
    
    /// Size and frame rate of the streams being drawn (or captured), refreshed about once a second.
    private var videoInfos = [MatrixRTCStreamRef: MatrixRTCVideoInfo]()
    
    public func videoInfo(memberID: String, kind: MatrixRTCStreamKind = .camera) -> MatrixRTCVideoInfo? {
        videoInfos[MatrixRTCStreamRef(memberID: memberID, kind: kind)]
    }
    
    /// Upright aspect ratio of a stream seen so far, so a surface can be sized before its first frame.
    public func videoAspect(memberID: String, kind: MatrixRTCStreamKind = .camera) -> CGFloat? {
        videoInfo(memberID: memberID, kind: kind)?.aspect
    }
    
    /// What was last asked of the SFU for a stream.
    public func requestedVideoConstraints(memberID: String, kind: MatrixRTCStreamKind = .camera) -> MatrixRTCVideoConstraints? {
        appliedConstraints[MatrixRTCStreamRef(memberID: memberID, kind: kind)]
    }
    
    /// What the call's own timers run on: the share intent timeout, the release linger, the audio
    /// level flush and the stats poll. Injected so a scenario can walk through a linger in one
    /// step; the continuous clock everywhere a session makes the call.
    private let clock: any Clock<Duration>
    /// Whether turning the camera on opens the device. Off for a scripted call: it has no track to
    /// send frames into, and the example app that plays scenarios has no camera usage string, so
    /// opening the device there is a privacy abort. The camera state still changes, so our tile
    /// follows it and the harness draws its test pattern there.
    private let capturesCamera: Bool
    
    init(localMemberID: String,
         mediaSession: any MediaSessionProtocol,
         clock: any Clock<Duration> = ContinuousClock(),
         capturesCamera: Bool = true) {
        self.localMemberID = localMemberID
        self.mediaSession = mediaSession
        self.clock = clock
        self.capturesCamera = capturesCamera
        (events, eventsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }
    
    /// Starts the event pump **before** anything announces the call as connected (the stream has no
    /// replay), then sweeps the roster for members already publishing.
    ///
    /// The tile roster and our own state are pumped separately, one task each: both suspend, and a
    /// single loop would have to race them and drop whichever it was not awaiting. Both are seeded
    /// here rather than left to their pumps, which would fill them a turn later — after `connectMedia`
    /// has already handed the call on. Same reason the event pump starts before anything announces
    /// the call connected: there is no replay.
    func start() async {
        tasks.append(Task { [weak self] in await self?.pumpEvents() })
        tasks.append(Task { [weak self] in await self?.pumpTileRoster() })
        tasks.append(Task { [weak self] in await self?.pumpLocalState() })
        tasks.append(Task { [weak self] in await self?.pollReceiveStats() })
        seedParticipants()
        apply(mediaSession.roster())
        apply(mediaSession.localState())
    }
    
    /// The transport's roster, read once: it is the whole call every time, which is the cost the tile
    /// roster's detail window exists to avoid, so it is never pumped or re-read per event. What it
    /// seeds is our own row, for the tile we draw before the core publishes our local state.
    private func seedParticipants() {
        participants = mediaSession.participants().map(MatrixRTCParticipant.init)
        MatrixRTCLog.info("Media roster \(participants.count): \(participants.map { "\($0.memberID)\($0.isLocal ? " (self)" : "")" })")
    }
    
    /// Who we play follows the tile roster, not the event stream: every remote person tile is a
    /// candidate, and a candidate we have no sink for is opened on each roster -- `audioStream`
    /// answers nil at once for a member with no microphone track, so the retries cost nothing and a
    /// microphone that appears later is picked up on the roster it changes. Anyone gone from the
    /// order loses their sink. A missed `streamStarted` can therefore never leave someone silent, and
    /// a missed `participantLeft` never leaks a sink.
    private func reconcilePlayback() {
        let wanted = Self.playbackCandidates(tiles.order, localMemberID: localMemberID)
        for memberID in playbackSinks.keys where !wanted.contains(memberID) {
            stopPlayback(of: memberID)
        }
        for memberID in wanted where playbackSinks[memberID] == nil {
            playAudio(of: memberID)
        }
    }
    
    /// Whose audio we try to play: every remote person tile in the order. Whether they have a
    /// microphone, opening it tells us.
    static func playbackCandidates(_ order: [MatrixRTCTileRef], localMemberID: String) -> Set<String> {
        Set(order.filter { $0.id.kind == .person && $0.id.memberID != localMemberID }.map(\.id.memberID))
    }
    
    // MARK: - Audio device
    
    /// From CallKit's `didActivate audioSession` (or directly on the simulator).
    ///
    /// Returns before the engine is actually running: starting it means reconfiguring the graph,
    /// which is exactly what must not happen synchronously on this thread.
    public func startAudio() {
        audioEngine.start()
    }
    
    /// From CallKit's `didDeactivate audioSession`.
    public func stopAudio() {
        audioEngine.stop()
    }
    
    // MARK: - Microphone
    
    /// `muted` goes into the publish itself rather than being applied after it, because the controls
    /// are on screen while the call is still joining: someone who mutes there would otherwise be
    /// published live for the moment between the track reaching the transport and the mute doing so.
    public func publishMicrophone(muted: Bool = false) async throws {
        guard microphoneTrack == nil else { return }
        let track: FfiLocalTrack
        do {
            track = try await mediaSession.publish(options: FfiPublishOptions(kind: .microphone,
                                                                              audio: FfiAudioSourceConfig(sampleRate: UInt32(AudioFormat.sampleRate),
                                                                                                          numChannels: UInt32(AudioFormat.channelCount)),
                                                                              video: nil,
                                                                              simulcast: false,
                                                                              muted: muted))
        } catch {
            throw MatrixRTCError.media("Failed to publish the microphone: \(error)")
        }
        microphoneTrack = track
        microphone.start(track: track)
        // The transport already knows, from the publish. This is what closes the capturer's own gate
        // and records the state.
        await setMicrophoneMuted(muted)
        MatrixRTCLog.info("Publishing microphone as \(localMemberID)")
    }
    
    /// Stops handing frames over **and** tells the transport, so peers see a deliberate mute rather
    /// than a client that wedged.
    public func setMicrophoneMuted(_ muted: Bool) async {
        isMicrophoneMuted = muted
        microphone.setMuted(muted)
        await setTransportMuted(.microphone, muted: muted)
    }
    
    // MARK: - Camera
    
    /// On: start capture, then unmute the transport. Off: **mute the transport first**, then release
    /// the device (a peer told afterwards has already been shown a frozen picture).
    public func setCameraEnabled(_ enabled: Bool) async throws {
        guard isCameraEnabled != enabled else { return }
        if enabled {
            let track: FfiLocalTrack
            if let cameraTrack {
                track = cameraTrack
            } else {
                do {
                    // simulcast is not a quality setting: with one layer dynacast pauses the only
                    // encoding nobody's small tile asked for and no video leaves the device.
                    track = try await mediaSession.publish(options: FfiPublishOptions(kind: .camera,
                                                                                      audio: nil,
                                                                                      video: FfiVideoSourceConfig(width: CameraCapturer.captureWidth,
                                                                                                                  height: CameraCapturer.captureHeight),
                                                                                      simulcast: true,
                                                                                      muted: false))
                } catch {
                    throw MatrixRTCError.media("Failed to publish the camera: \(error)")
                }
                cameraTrack = track
            }
            if capturesCamera {
                camera.setInterfaceOrientation(currentInterfaceOrientation)
                try camera.start(track: track)
                isFrontCamera = camera.isFrontFacing
            }
            await setTransportMuted(.camera, muted: false)
        } else {
            await setTransportMuted(.camera, muted: true)
            if capturesCamera {
                camera.stop()
            }
        }
        isCameraEnabled = enabled
        MatrixRTCLog.info("Camera \(enabled ? "enabled" : "disabled") for \(localMemberID)")
    }
    
    public func switchCamera() throws {
        guard capturesCamera else {
            isFrontCamera.toggle()
            return
        }
        isFrontCamera = try camera.switchCamera()
    }
    
    /// Anyone (us included) has video worth showing.
    public var hasVideo: Bool {
        (isCameraEnabled && !isCameraInterrupted) || tiles.detail.values.contains { $0.hasVideo }
    }
    
    /// What a single-tile surface (Picture in Picture) should show: the spotlight tile if it still
    /// has a picture, else the highest-ranked remote tile with video, else our own camera.
    ///
    /// Reads the tile roster: it is the one surface kept live for the whole call, and its order puts
    /// a shared screen first, which is what a window with room for one thing should show.
    public func pictureInPictureCandidate(spotlight: MatrixRTCTileID?) -> MatrixRTCTileID? {
        Self.pictureInPictureCandidate(tiles: tiles,
                                       localMemberID: localMemberID,
                                       isLocalCameraAvailable: isCameraEnabled && !isCameraInterrupted,
                                       spotlight: spotlight)
    }
    
    public nonisolated static func pictureInPictureCandidate(tiles: MatrixRTCTileRoster,
                                                             localMemberID: String,
                                                             isLocalCameraAvailable: Bool,
                                                             spotlight: MatrixRTCTileID?) -> MatrixRTCTileID? {
        // The spotlight names its own stream, so this only has to check the one it names still has
        // a picture -- a share can stop while the window is continuing it.
        if let spotlight, spotlight.memberID != localMemberID, tiles.detail[spotlight]?.hasVideo == true {
            return spotlight
        }
        if let remote = tiles.order.first(where: { tiles.detail[$0.id]?.hasVideo == true }) {
            return remote.id
        }
        if isLocalCameraAvailable {
            return MatrixRTCTileID(memberID: localMemberID, kind: .person)
        }
        return nil
    }
    
    /// Who the single-tile surface should *name* when nobody has video and it falls back to an
    /// avatar. Separate from ``pictureInPictureCandidate(spotlight:)``, which answers what stream to
    /// show and returns nil in exactly that case.
    ///
    /// A member rather than a tile, because this names a person.
    public func pictureInPicturePlaceholderMemberID(spotlight: MatrixRTCTileID?) -> String? {
        Self.pictureInPicturePlaceholderMemberID(tiles: tiles, spotlight: spotlight)
    }
    
    public nonisolated static func pictureInPicturePlaceholderMemberID(tiles: MatrixRTCTileRoster,
                                                                       spotlight: MatrixRTCTileID?) -> String? {
        // The order never holds our own tile, so a spotlight found in it is somebody else -- showing
        // the user their own avatar would tell them nothing about who they are talking to.
        if let spotlight, tiles.order.contains(where: { $0.id.memberID == spotlight.memberID }) {
            return spotlight.memberID
        }
        return tiles.order.first?.id.memberID
    }
    
    private func handleCameraInterruption(_ interrupted: Bool) async {
        guard isCameraEnabled, isCameraInterrupted != interrupted else { return }
        isCameraInterrupted = interrupted
        // The user's camera choice stays what it was; only the transport state follows the interruption.
        await setTransportMuted(.camera, muted: interrupted)
    }
    
    public func updateInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        guard capturesCamera else { return }
        camera.setInterfaceOrientation(orientation)
    }
    
    // MARK: - Screen share
    
    /// A screen has no "off": stopping **unpublishes** rather than mutes, otherwise every peer keeps
    /// drawing an empty tile for a share that ended.
    public func setScreenShareEnabled(_ enabled: Bool) async throws {
        guard isScreenSharing != enabled else { return }
        setPendingScreenShare(enabled)
        if enabled {
            let track: FfiLocalTrack
            do {
                track = try await mediaSession.publish(options: FfiPublishOptions(kind: .screenShare,
                                                                                  audio: nil,
                                                                                  video: FfiVideoSourceConfig(width: UInt32(ScreenShareCapturer.maxLongEdge),
                                                                                                              height: UInt32(ScreenShareCapturer.maxLongEdge * 9 / 16)),
                                                                                  simulcast: true,
                                                                                  muted: false))
            } catch {
                throw MatrixRTCError.media("Failed to publish the screen share: \(error)")
            }
            do {
                try await screenShare.start(track: track)
            } catch {
                try? await mediaSession.unpublish(kind: .screenShare)
                // The intent goes back now rather than waiting out the deadline: the banner should
                // not sit there for ten seconds after a share that never started.
                setPendingScreenShare(nil)
                throw error
            }
            await setTransportMuted(.screenShare, muted: false)
        } else {
            await screenShare.stop()
            do {
                try await mediaSession.unpublish(kind: .screenShare)
            } catch {
                MatrixRTCLog.warning("Could not unpublish the screen share: \(error)")
            }
        }
        MatrixRTCLog.info("Screen share \(enabled ? "started" : "stopped") requested for \(localMemberID)")
        reconcileScreenShare()
    }
    
    /// ReplayKit stopped without us asking — Control Centre, another app taking the recorder, a
    /// restriction. The publication is still up, so the core still reports us as sharing, because
    /// from the transport's point of view we are: it cannot see ReplayKit and learns a share ended
    /// only because we unpublished.
    ///
    /// Retracting the publication is the only thing that makes both true again. Unpublish rather
    /// than mute, for the same reason stopping deliberately does: a screen has no "off" state a mute
    /// could stand for, so peers would go on drawing an empty tile — and under the tile model that
    /// tile is a hero, sitting in the largest slot every one of them has.
    private func handleScreenShareStopped() async {
        guard isScreenSharing || pendingScreenShare == true else { return }
        MatrixRTCLog.info("Screen capture ended without us asking; unpublishing the share")
        setPendingScreenShare(false)
        await screenShare.stop()
        do {
            try await mediaSession.unpublish(kind: .screenShare)
        } catch {
            MatrixRTCLog.warning("Could not unpublish after an unexpected screen capture stop: \(error)")
        }
        reconcileScreenShare()
    }
    
    private func setPendingScreenShare(_ pending: Bool?) {
        screenShareIntentDeadline?.cancel()
        pendingScreenShare = pending
        guard pending != nil else {
            screenShareIntentDeadline = nil
            return
        }
        let clock = clock
        screenShareIntentDeadline = Task { [weak self] in
            try? await clock.sleep(for: Self.screenShareIntentTimeout)
            guard !Task.isCancelled, let self, pendingScreenShare != nil else { return }
            MatrixRTCLog.warning("Screen share intent was never confirmed by the core; deferring to its state")
            setPendingScreenShare(nil)
        }
    }
    
    /// Drops the optimistic value once the core says the same thing, so from then on there is one
    /// answer rather than two that can drift.
    private func reconcileScreenShare() {
        guard let pendingScreenShare, pendingScreenShare == localState?.isScreenSharing else { return }
        setPendingScreenShare(nil)
    }
    
    // MARK: - Remote video
    
    /// Attaches a tile's slot to the member's stream, opening the decoder on first attach.
    public func attachVideo(_ slot: VideoFrameSlot, memberID: String, kind: MatrixRTCStreamKind = .camera) {
        let key = MatrixRTCStreamRef(memberID: memberID, kind: kind)
        let source = videoSources[key] ?? {
            let mediaSession = mediaSession
            let source = RemoteVideoSource(open: {
                mediaSession.videoStream(memberId: memberID, kind: kind.ffi).map(VideoFrameStreamBox.init)
            }, onIdle: { [weak self] in
                // Nobody draws it any more: stop asking the SFU for it.
                Task { @MainActor in self?.setVideoConstraints(.init(isVisible: false, pixelSize: nil), memberID: memberID, kind: kind) }
            }, clock: clock)
            source.onVideoInfo = { [weak self] info in
                Task { @MainActor in self?.videoInfos[key] = info }
            }
            videoSources[key] = source
            return source
        }()
        source.attach(slot)
        // A tile only attaches once it is on screen, so whatever the stage last decided about this
        // stream is out of date the moment we get here: drop the release before asking for it, or
        // the diff below would immediately take it away again.
        if let tile = key.tileID {
            releasedVideoStreams.remove(tile)
        }
        // A tile that comes back after the stream went idle (or was released) needs the SFU sending
        // again; the tile's own size report refines this shortly after. A tile mounting into the
        // paused band is subscribed but not sent: it is the stage that says when it is looked at.
        let applied = appliedConstraints[key]
        let isPaused = key.tileID.map { pausedVideoStreams.contains($0) } ?? false
        if applied == nil || applied?.isVisible == false || applied?.isEnabled == false {
            setVideoConstraints(.init(isVisible: !isPaused, pixelSize: applied?.pixelSize), memberID: memberID, kind: kind)
        }
    }
    
    public func detachVideo(_ slot: VideoFrameSlot, memberID: String, kind: MatrixRTCStreamKind = .camera) {
        videoSources[MatrixRTCStreamRef(memberID: memberID, kind: kind)]?.detach(slot)
        reportDrawnSize(nil, slot: slot, memberID: memberID, kind: kind)
    }
    
    /// Drawn sizes per surface, so the SFU is asked for the largest of everything currently showing
    /// a stream rather than for whichever surface happened to lay out last.
    private var drawnSizes = [MatrixRTCStreamRef: [UUID: CGSize]]()
    /// Streams paused and waiting out ``releaseLinger`` before they are released.
    private var pendingReleases = [MatrixRTCTileID: Task<Void, Never>]()
    
    /// A surface reports how big it draws a stream (nil when it stops drawing it).
    public func reportDrawnSize(_ size: CGSize?, slot: VideoFrameSlot, memberID: String, kind: MatrixRTCStreamKind = .camera) {
        guard memberID != localMemberID else { return }
        let key = MatrixRTCStreamRef(memberID: memberID, kind: kind)
        // A surface that is still laid out but paused or released (a paused tile keeps its view
        // mounted so its last picture is there when it scrolls in; Picture in Picture keeps one
        // alive) must not re-subscribe the stream behind the stage's back. The size is kept, so
        // the stream comes back at the right size when the stage says so.
        guard let tile = key.tileID, !releasedVideoStreams.contains(tile), !pausedVideoStreams.contains(tile) else {
            if size != nil, let tile = key.tileID, pausedVideoStreams.contains(tile) {
                var sizes = drawnSizes[key] ?? [:]
                sizes[slot.id] = size
                drawnSizes[key] = sizes
            }
            return
        }
        var sizes = drawnSizes[key] ?? [:]
        sizes[slot.id] = size
        drawnSizes[key] = sizes.isEmpty ? nil : sizes
        guard let largest = sizes.values.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            // The idle path (linger) tells the SFU to stop; nothing to ask for meanwhile.
            return
        }
        setVideoConstraints(.init(isVisible: true, pixelSize: largest), memberID: memberID, kind: kind)
    }
    
    /// Say how big the tile really is; the SFU then sends the layer that fits. De-duplicated: layout
    /// recomputes on every pass and most land on the same numbers.
    public func setVideoConstraints(_ constraints: MatrixRTCVideoConstraints, memberID: String, kind: MatrixRTCStreamKind = .camera) {
        // Our own streams are not subscribed from the SFU; and layout jitters by a pixel between
        // passes, which is not news worth a round trip: snap to a 16 px grid.
        guard memberID != localMemberID else { return }
        let constraints = MatrixRTCVideoConstraints(isEnabled: constraints.isEnabled,
                                                    isVisible: constraints.isEnabled && constraints.isVisible,
                                                    pixelSize: constraints.pixelSize.map { size in
                                                        CGSize(width: (size.width / 16).rounded() * 16, height: (size.height / 16).rounded() * 16)
                                                    })
        let key = MatrixRTCStreamRef(memberID: memberID, kind: kind)
        guard appliedConstraints[key] != constraints else { return }
        appliedConstraints[key] = constraints
        MatrixRTCLog.info("Constraints for \(memberID) (\(kind)): enabled=\(constraints.isEnabled) visible=\(constraints.isVisible) size=\(constraints.pixelSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "auto")")
        
        let detail: FfiVideoDetail = if constraints.isVisible, let size = constraints.pixelSize {
            .dimensions(width: UInt32(size.width), height: UInt32(size.height))
        } else {
            .auto
        }
        let mediaSession = mediaSession
        mediaRequests.async {
            mediaSession.setConstraints(memberId: memberID,
                                        kind: kind.ffi,
                                        constraints: FfiMediaConstraints(enabled: constraints.isEnabled, visible: constraints.isVisible, detail: detail, lowBandwidth: false))
        }
    }
    
    /// Returns once every constraint and window declared so far has reached the session.
    func drainMediaRequests() async {
        await withCheckedContinuation { continuation in
            mediaRequests.async { continuation.resume() }
        }
    }
    
    /// How long a member stays merely paused before being released outright. Long enough to cover
    /// looking at one tile and changing your mind, short enough that actually settling on one frees
    /// the call's bandwidth.
    private static let releaseLinger = Duration.seconds(3)
    
    /// The streams the stage is no longer drawing, hidden because they are more than a viewport
    /// away or because one tile has the whole screen. Nothing is paused.
    public func setReleasedVideoStreams(_ tileIDs: Set<MatrixRTCTileID>) {
        setVideoVisibility(paused: [], released: tileIDs)
    }
    
    /// What the stage is not showing, in the two ways the core tells apart (003 R48, R56, R58).
    ///
    /// **Per stream, not per member, and that is the whole point.** This used to take member IDs and
    /// walk both kinds for each, which was right for exactly as long as a member was one tile. A
    /// member publishing a camera and a screen share is two tiles that are drawn in different places
    /// and go off screen at different times: their share is the hero in the spotlight while their
    /// camera can be a scroll away in the grid. Releasing "the member" then takes down the picture
    /// everybody is looking at, three seconds after a scroll, and nothing catches it — it compiles,
    /// and no fixture in the test suite has one member on two tiles.
    ///
    /// **Paused** streams are within a scroll of the screen: subscribed but not sent, so they resume
    /// the instant they are looked at and their tile keeps its last picture meanwhile. They are never
    /// released by the linger. **Released** streams are further away, or hidden: paused at once and
    /// released only if still named a few seconds later, because releasing frees the subscription
    /// but costs a visible re-negotiation to undo. Going full screen and straight back out, or a
    /// tile bouncing at the edge of the band, then costs nothing, while settling somewhere still
    /// gives a two-hundred-person call its bandwidth back. A stream no tile has ever asked for has
    /// nothing to come back to, and is released at once.
    ///
    /// A stream leaving both sets while its tile is still mounted is asked for again at the size
    /// that tile last reported: a paused tile does not re-attach when it scrolls back in, so its
    /// own attach cannot be what says it is being drawn again.
    ///
    /// Sets rather than per-tile calls so there is one place that knows what is not shown. An
    /// earlier shape had each tile release itself on the way out, and members who left while off
    /// screen were never restored, because the tile that owed them the call had gone.
    public func setVideoVisibility(paused pausedIDs: Set<MatrixRTCTileID>, released releasedIDs: Set<MatrixRTCTileID>) {
        let released = releasedIDs.filter { $0.memberID != localMemberID }
        let paused = pausedIDs.filter { $0.memberID != localMemberID }.subtracting(released)
        guard released != releasedVideoStreams || paused != pausedVideoStreams else { return }
        // Only the streams that changed side need a round trip; setVideoConstraints de-duplicates
        // the rest anyway, but a big call would otherwise walk every stream on every scroll.
        let changed = released.symmetricDifference(releasedVideoStreams).union(paused.symmetricDifference(pausedVideoStreams))
        releasedVideoStreams = released
        pausedVideoStreams = paused
        for tile in changed {
            // Whichever way this stream just went, any release still waiting on it is stale.
            pendingReleases.removeValue(forKey: tile)?.cancel()
            let key = MatrixRTCStreamRef(tile)
            let applied = appliedConstraints[key]
            if released.contains(tile) {
                // A surface going away reports a nil size, and `reportDrawnSize` drops that report
                // when the stream is already released. Releasing and unmounting happen in one pass
                // and in no defined order, so whenever the release lands first the departing
                // surface's size would stay here for the rest of the call and go on inflating the
                // maximum for whoever draws the stream next.
                drawnSizes[key] = nil
                // Never drawn, so nothing to come back to: the linger would only hold the core's
                // default subscription open. At a join of two hundred that is most of the call.
                guard let applied else {
                    setVideoConstraints(.init(isEnabled: false, isVisible: false, pixelSize: nil),
                                        memberID: tile.memberID,
                                        kind: tile.kind.videoStreamKind)
                    continue
                }
                setVideoConstraints(.init(isEnabled: true, isVisible: false, pixelSize: applied.pixelSize),
                                    memberID: tile.memberID,
                                    kind: tile.kind.videoStreamKind)
                pendingReleases[tile] = clock.schedule(after: Self.releaseLinger) { [weak self] in self?.release(tile) }
            } else if paused.contains(tile) {
                setVideoConstraints(.init(isEnabled: true, isVisible: false, pixelSize: applied?.pixelSize),
                                    memberID: tile.memberID,
                                    kind: tile.kind.videoStreamKind)
            } else if let largest = drawnSizes[key]?.values.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                // Back on screen with its view still mounted: nothing else will ask for it.
                setVideoConstraints(.init(isEnabled: true, isVisible: true, pixelSize: largest),
                                    memberID: tile.memberID,
                                    kind: tile.kind.videoStreamKind)
            }
            // Otherwise it is the tile's own attach that says it is being drawn again and at
            // what size.
        }
    }
    
    /// Declares which tiles the layout wants full records for (003 R52, R55). The core republishes
    /// the roster on every declaration, so an equal window must never reach it: the layout
    /// recomputes on every scroll and most passes land on the same rows.
    public func setDetailWindow(_ window: MatrixRTCDetailWindow) {
        guard window != appliedDetailWindow else { return }
        appliedDetailWindow = window
        MatrixRTCLog.info("Detail window ranks \(window.ranks.lowerBound)..<\(window.ranks.upperBound) also \(window.also.map { "\($0.memberID)/\($0.kind)" })")
        let mediaSession = mediaSession
        let also = window.also.map { FfiTileId(memberId: $0.memberID, kind: $0.kind.ffi) }
        mediaRequests.async {
            mediaSession.setDetailWindow(offset: UInt32(clamping: window.ranks.lowerBound),
                                         len: UInt32(clamping: window.ranks.count),
                                         also: also)
        }
    }
    
    /// The last window declared, for a dump or a test.
    public var detailWindow: MatrixRTCDetailWindow? {
        appliedDetailWindow
    }
    
    /// The second step of ``setVideoVisibility(paused:released:)``, once the stream has stayed unwatched.
    private func release(_ tile: MatrixRTCTileID) {
        pendingReleases[tile] = nil
        // It may have come back while this was waiting, in which case the cancel above raced us.
        guard releasedVideoStreams.contains(tile) else { return }
        let applied = appliedConstraints[MatrixRTCStreamRef(tile)]
        setVideoConstraints(.init(isEnabled: false, isVisible: false, pixelSize: applied?.pixelSize),
                            memberID: tile.memberID,
                            kind: tile.kind.videoStreamKind)
    }
    
    // MARK: - Teardown
    
    public func disconnect() async {
        pendingReleases.values.forEach { $0.cancel() }
        pendingReleases.removeAll()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        audioLevelFlush?.cancel()
        audioLevelFlush = nil
        microphone.stop()
        if capturesCamera {
            camera.stop()
        }
        await screenShare.stop()
        playbackSinks.values.forEach { $0.stop() }
        playbackSinks.removeAll()
        videoSources.values.forEach { $0.close() }
        videoSources.removeAll()
        releasedVideoStreams.removeAll()
        // Stops the engine *and* detaches every node in one hop. Each `stop()` above only flips a
        // flag and enqueues its detach, so the whole audio teardown costs this actor microseconds
        // rather than blocking it on graph reconfiguration — which is what the render thread used
        // to deadlock against.
        audioEngine.shutdown()
        do {
            try await mediaSession.disconnect()
        } catch {
            MatrixRTCLog.warning("Failed to disconnect the media session: \(error)")
        }
        eventsContinuation.finish()
    }
    
    // MARK: - Private
    
    private var currentInterfaceOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.interfaceOrientation ?? .portrait
    }
    
    /// The ranked tiles, pushed. Latest-value-wins on the far side, so falling behind costs the
    /// intermediate rosters rather than building a backlog of superseded ones.
    private func pumpTileRoster() async {
        while !Task.isCancelled, let roster = await mediaSession.nextRoster() {
            apply(roster)
        }
        // Three pumps can now observe the session ending and only `pumpEvents` yields `.ended`.
        // Saying so distinguishes a stage frozen on its last roster from one nobody is updating.
        MatrixRTCLog.debug("Tile roster pump stopped (hasEnded: \(hasEnded))")
    }
    
    private func pumpLocalState() async {
        while !Task.isCancelled, let state = await mediaSession.nextLocalState() {
            apply(state)
        }
        MatrixRTCLog.debug("Local state pump stopped (hasEnded: \(hasEnded))")
    }
    
    private func apply(_ roster: FfiTileRoster) {
        let mapped = MatrixRTCTileRoster(roster, localMemberID: localMemberID)
        // Bail before assigning, for the reason `refreshParticipants` gives: every tile view reads
        // this, and per-tile state publishes immediately rather than waiting out the model's
        // reorder window, so an unconditional write would rebuild the stage on every flicker.
        guard mapped != tiles else { return }
        if mapped.order.map(\.id) != tiles.order.map(\.id) {
            MatrixRTCLog.info("Tiles (\(mapped.order.count)): \(mapped.order.map { "\($0.id.memberID)/\($0.id.kind)\($0.isHero ? " hero" : "")" })")
        }
        tiles = mapped
        reconcilePlayback()
    }
    
    private func apply(_ state: FfiLocalState?) {
        let mapped = state.map { MatrixRTCLocalState($0, localMemberID: localMemberID) }
        guard mapped != localState else { return }
        localState = mapped
        reconcileScreenShare()
    }
    
    private func pumpEvents() async {
        while !Task.isCancelled, let ffiEvent = await mediaSession.nextEvent() {
            let event = MatrixRTCCallEvent(ffiEvent)
            handle(event)
            eventsContinuation.yield(event)
        }
        MatrixRTCLog.debug("Media event pump stopped")
    }
    
    private func handle(_ event: MatrixRTCCallEvent) {
        switch event {
        case .frameEncryptionState(let memberID, let state):
            if frameEncryption[memberID] != state {
                MatrixRTCLog.warning("Frame encryption \(state) for \(memberID) (was \(frameEncryption[memberID].map { "\($0)" } ?? "unknown"))")
            }
            frameEncryption[memberID] = state
        case .keyDiscarded(let memberID, let reason):
            MatrixRTCLog.warning("Key for \(memberID) discarded: \(reason)")
        case .keyImported(let memberID, let keyIndex):
            MatrixRTCLog.info("Key index \(keyIndex) imported for \(memberID)")
        case .mediaConnectionDegraded(let degraded):
            isMediaDegraded = degraded
        case .ended(let reason):
            MatrixRTCLog.info("Media session ended: \(reason)")
            hasEnded = true
            playbackSinks.values.forEach { $0.stop() }
            playbackSinks.removeAll()
        default:
            break
        }
    }
    
    /// Reached from the roster only; the dictionary claim keeps a member from being played twice.
    private func playAudio(of memberID: String) {
        guard memberID != localMemberID, playbackSinks[memberID] == nil else { return }
        guard let stream = mediaSession.audioStream(memberId: memberID, kind: .microphone) else {
            // Said once: a member the SFU relays to everyone else but whose microphone never reaches
            // our roster used to look exactly like a quiet participant. The next roster tries again.
            if membersWithoutMicrophone.insert(memberID).inserted {
                MatrixRTCLog.warning("\(memberID) publishes no microphone stream, so they cannot be heard here")
            }
            return
        }
        membersWithoutMicrophone.remove(memberID)
        let sink = AudioPlaybackSink(memberID: memberID, engine: audioEngine) { [weak self] memberID, level in
            Task { @MainActor in self?.setAudioLevel(level, for: memberID) }
        }
        playbackSinks[memberID] = sink
        sink.start(stream: stream)
        MatrixRTCLog.info("Playing audio of \(memberID)")
    }
    
    private func stopPlayback(of memberID: String) {
        playbackSinks.removeValue(forKey: memberID)?.stop()
        audioLevels[memberID] = nil
        pendingAudioLevels[memberID] = nil
        for key in videoSources.keys where key.memberID == memberID {
            videoSources.removeValue(forKey: key)?.close()
        }
    }
    
    /// Meters report ten times a second *per member*; published one by one, an eleven-person call
    /// would rebuild every tile over a hundred times a second. Levels are collected here and
    /// published in one batch per sample period, which is all a meter needs.
    ///
    /// This is the *level*, not whether somebody is speaking. Those used to be the same code: the
    /// level was thresholded here to synthesise a speaker set, because the transport's own
    /// active-speaker events had not been seen through the core. The model ranks on its own signal
    /// now and publishes `speaking` on each tile, so a locally derived answer would only be a second
    /// opinion for the ring to disagree with the order about.
    private static let audioLevelSamplePeriod: Duration = .milliseconds(100)
    @ObservationIgnored private var pendingAudioLevels: [String: MatrixRTCAudioLevel] = [:]
    @ObservationIgnored private var audioLevelFlush: Task<Void, Never>?
    
    private func setAudioLevel(_ level: MatrixRTCAudioLevel, for memberID: String?) {
        guard let memberID else { return }
        pendingAudioLevels[memberID] = level
        guard audioLevelFlush == nil else { return }
        let clock = clock
        audioLevelFlush = Task { [weak self] in
            try? await clock.sleep(for: Self.audioLevelSamplePeriod)
            guard !Task.isCancelled else { return }
            self?.flushAudioLevels()
        }
    }
    
    private func flushAudioLevels() {
        audioLevelFlush = nil
        guard !pendingAudioLevels.isEmpty else { return }
        var levels = audioLevels
        for (memberID, level) in pendingAudioLevels {
            levels[memberID] = level
        }
        pendingAudioLevels.removeAll(keepingCapacity: true)
        // Deliberately unguarded, unlike `refreshParticipants()` above: `MatrixRTCAudioLevel` carries
        // a monotonic `frameCount`, so two flushes for a live member never compare equal and the
        // guard could not fire. Nothing observing this may project it into a view.
        audioLevels = levels
    }
    
    /// RTCP reports arrive about once a second; polling faster only repeats values.
    private func pollReceiveStats() async {
        while !Task.isCancelled {
            try? await clock.sleep(for: .seconds(1))
            // One round trip for the streams we draw, not one per member: at two hundred participants
            // the old loop was two hundred sequential awaits a second, for tiles nobody was looking at.
            let streams = Self.streamsToPoll(tiles: tiles, released: releasedVideoStreams, localMemberID: localMemberID)
            var stats = [MatrixRTCStreamRef: MatrixRTCReceiveStats]()
            if !streams.isEmpty {
                let answered = await mediaSession.receiveStatsFor(streams: streams.map { FfiStreamRef(memberId: $0.memberID, kind: $0.kind.ffi) })
                for entry in answered {
                    // Null until the first RTCP report, which is not the same as zero.
                    if let counters = entry.stats {
                        stats[MatrixRTCStreamRef(memberID: entry.memberId, kind: .init(entry.kind))] = .init(counters)
                    }
                }
            }
            // The same guard as `refreshParticipants()` above. Its reach is modest -- the counters
            // move whenever audio is arriving -- but alone in a call this is empty every second.
            if stats != receiveStats {
                receiveStats = stats
            }
        }
    }
    
    /// The streams one stats sample asks about: every remote tile we are drawing -- the order minus
    /// what ``setReleasedVideoStreams(_:)`` has released -- then one microphone per member among
    /// them. In that order, without repeats, so the answer reads as the stage does.
    static func streamsToPoll(tiles: MatrixRTCTileRoster, released: Set<MatrixRTCTileID>, localMemberID: String) -> [MatrixRTCStreamRef] {
        let drawn = tiles.order.map(\.id).filter { $0.memberID != localMemberID && !released.contains($0) }
        var seen = Set<String>()
        let microphones = drawn.compactMap { tile -> MatrixRTCStreamRef? in
            seen.insert(tile.memberID).inserted ? MatrixRTCStreamRef(memberID: tile.memberID, kind: .microphone) : nil
        }
        return drawn.map(MatrixRTCStreamRef.init) + microphones
    }
    
    private func setTransportMuted(_ kind: MatrixRTCStreamKind, muted: Bool) async {
        do {
            try await mediaSession.setLocalMuted(kind: kind.ffi, muted: muted)
        } catch {
            MatrixRTCLog.warning("Could not tell the transport \(kind) is \(muted ? "muted" : "unmuted"): \(error)")
        }
    }
}

/// Fans the local camera frames out to every self-view slot.
@available(iOS 18, *)
public final nonisolated class LocalVideoFanOut: Sendable {
    private let slots = Mutex<[UUID: VideoFrameSlot]>([:])
    
    public func attach(_ slot: VideoFrameSlot) {
        slots.withLock { $0[slot.id] = slot }
    }
    
    public func detach(_ slot: VideoFrameSlot) {
        slots.withLock { $0[slot.id] = nil }; slot.clear()
    }
    
    func offer(_ frame: MatrixRTCVideoFrame) {
        for slot in slots.withLock({ Array($0.values) }) {
            slot.offer(frame)
        }
    }
}

@available(iOS 18, *)
private extension Clock where Duration == Swift.Duration {
    /// Runs `body` on the main actor once `duration` has passed on this clock, unless cancelled first.
    ///
    /// The deadline is taken now, not in the task: a `sleep(for:)` there reads the clock whenever the
    /// task first runs, which on a manual clock can be after it was advanced past the deadline.
    func schedule(after duration: Duration, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        let deadline = now.advanced(by: duration)
        return Task { @MainActor in
            try? await sleep(until: deadline, tolerance: nil)
            guard !Task.isCancelled else { return }
            body()
        }
    }
}
