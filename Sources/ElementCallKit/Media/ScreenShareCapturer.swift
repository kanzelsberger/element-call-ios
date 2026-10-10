//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CoreMedia
import MatrixRtc
import ReplayKit
import Synchronization

/// In-app screen capture through ReplayKit: no extension, no app-group IPC, captures this app only.
/// A system-wide share needs a Broadcast Upload Extension (documented follow-up).
///
/// A screen is mostly still and every pixel is repacked on the way out, so this caps the long edge
/// and halves the frame rate.
@available(iOS 18, *)
final nonisolated class ScreenShareCapturer: @unchecked Sendable {
    static let maxLongEdge = 1280
    static let frameInterval: TimeInterval = 1.0 / 15.0
    
    private let state = Mutex<State>(.init())
    private let observer = ScreenRecorderObserver()
    
    private struct State {
        var track: FfiLocalTrack?
        var lastTimestamp: TimeInterval = 0
        var isCapturing = false
        /// Set as soon as ``stop()`` is entered, so the callbacks our own stop provokes are not
        /// mistaken for the recorder stopping on its own.
        var stopRequested = false
        /// Boxed in this struct rather than held in a `Mutex` of its own: each `withLock` on a
        /// generic mutex holding a function value reabstracts it and writes back one more thunk.
        var onUnexpectedStop: (@Sendable () -> Void)?
    }
    
    var isCapturing: Bool {
        state.withLock { $0.isCapturing }
    }
    
    /// Called when capture stops for a reason we did not ask for: the user stopping it from Control
    /// Centre, another app taking the recorder, or ReplayKit failing mid-stream.
    ///
    /// This exists because of what the *core* now does with it. Our sharing flag is derived from
    /// publication state — the stream up and unmuted — and the core cannot see ReplayKit: it learns
    /// a share ended only because we unpublished. A capture that stops without us tearing the
    /// publication down therefore leaves us telling every peer we are still sharing, and a live
    /// screen-share publication is a *hero* tile, so what they get is a frozen frame in the largest
    /// slot on their screen, indefinitely, with nothing on either side able to tell.
    ///
    /// Set before ``start(track:)``. Fires at most once per capture.
    func setOnUnexpectedStop(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.onUnexpectedStop = handler }
    }
    
    /// Latches, so several signals for one stop produce one handler call.
    private func declareUnexpectedStop(_ reason: String) {
        // The handler re-enters this object and `Mutex` is not reentrant, so it is copied out under
        // the lock and called outside it.
        let handler = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.isCapturing, !state.stopRequested else { return nil }
            state.isCapturing = false
            state.track = nil
            return state.onUnexpectedStop
        }
        guard let handler else { return }
        MatrixRTCLog.warning("Screen capture stopped without us asking: \(reason)")
        handler()
    }
    
    func start(track: FfiLocalTrack) async throws {
        state.withLock { state in
            state.track = track
            state.isCapturing = true
            state.stopRequested = false
        }
        let recorder = RPScreenRecorder.shared()
        // The recorder is a singleton and tells us when it stops for reasons of its own. Which of
        // its callbacks actually fires for in-app `startCapture` rather than `startRecording` is
        // undocumented, which is why the sample handler's own error below is wired to the same
        // latch: between them one will arrive, and the latch makes it harmless if both do.
        observer.onStop = { [weak self] in self?.declareUnexpectedStop("the recorder stopped") }
        observer.onUnavailable = { [weak self] in self?.declareUnexpectedStop("the recorder became unavailable") }
        recorder.delegate = observer
        // ReplayKit answers -5803 "Recording failed to start" for many reasons it will not name;
        // the two it does expose are worth having in the error.
        guard recorder.isAvailable else {
            state.withLock { $0.isCapturing = false }
            throw MatrixRTCError.media("Screen recording is unavailable (restricted, or another app is recording)")
        }
        if recorder.isRecording {
            MatrixRTCLog.warning("Screen recorder still reports an active recording before capture starts")
        }
        recorder.isMicrophoneEnabled = false
        // ReplayKit calls back on its own queues. The sample handler is a method reference: a
        // closure literal here would inherit the caller's actor and trap, and marking it `@Sendable`
        // hands its non-Sendable sample over as `sending`, so the bridged block over-releases it.
        // The completion handler only carries an Error and can be `@Sendable`. ReplayKit may also
        // call a completion handler more than once, and resuming twice traps.
        let resume = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recorder.startCapture(handler: handleCapture, completionHandler: { @Sendable error in
                resume.perform {
                    if let error {
                        continuation.resume(throwing: MatrixRTCError.media("Screen capture failed to start: \(error)"))
                    } else {
                        MatrixRTCLog.info("Screen capture started")
                        continuation.resume()
                    }
                }
            })
        }
    }
    
    func stop() async {
        let wasCapturing = state.withLock { state -> Bool in
            defer {
                state.track = nil
                state.isCapturing = false
                // Before anything else: stopping the recorder calls back, and without this those
                // callbacks would be reported as the recorder stopping on its own.
                state.stopRequested = true
            }
            return state.isCapturing
        }
        RPScreenRecorder.shared().delegate = nil
        guard wasCapturing else { return }
        let resume = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RPScreenRecorder.shared().stopCapture { @Sendable error in
                if let error {
                    MatrixRTCLog.warning("Screen capture stop error: \(error)")
                }
                resume.perform { continuation.resume() }
            }
        }
        MatrixRTCLog.info("Screen capture stopped")
    }
    
    private func handleCapture(_ sampleBuffer: CMSampleBuffer, _ type: RPSampleBufferType, _ error: Error?) {
        if let error {
            // ReplayKit reports the end of a capture here as well as through the delegate, and this
            // one is the path we know is wired: it used to be logged and dropped, which is how a
            // capture could end while the publication stayed up.
            declareUnexpectedStop("\(error)")
            return
        }
        guard type == .video else { return }
        handle(sampleBuffer)
    }
    
    private func handle(_ sampleBuffer: CMSampleBuffer) {
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let track = state.withLock { state -> FfiLocalTrack? in
            guard state.isCapturing, timestamp - state.lastTimestamp >= Self.frameInterval else { return nil }
            state.lastTimestamp = timestamp
            return state.track
        }
        guard let track, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let planes = I420Repacker.repack(pixelBuffer, maxLongEdge: Self.maxLongEdge) else { return }
        do {
            try track.captureVideo(frame: planes.ffiFrame(rotation: .deg0, timestampUs: Int64(timestamp * 1_000_000)))
        } catch {
            // A frame in flight while the share is being unpublished lands here; expected once per stop.
            MatrixRTCLog.debug("Screen share captureVideo failed: \(error)")
        }
    }
}

/// Bridges `RPScreenRecorderDelegate`, which needs an `NSObject`, without making the capturer one.
@available(iOS 18, *)
private final nonisolated class ScreenRecorderObserver: NSObject, RPScreenRecorderDelegate, @unchecked Sendable {
    private let handlers = Mutex<Handlers>(.init())
    
    private struct Handlers {
        var onStop: (@Sendable () -> Void)?
        var onUnavailable: (@Sendable () -> Void)?
    }
    
    var onStop: (@Sendable () -> Void)? {
        get { handlers.withLock(\.onStop) }
        set { handlers.withLock { $0.onStop = newValue } }
    }
    
    var onUnavailable: (@Sendable () -> Void)? {
        get { handlers.withLock(\.onUnavailable) }
        set { handlers.withLock { $0.onUnavailable = newValue } }
    }
    
    func screenRecorder(_ screenRecorder: RPScreenRecorder,
                        didStopRecordingWith previewViewController: RPPreviewViewController?,
                        error: Error?) {
        handlers.withLock(\.onStop)?()
    }
    
    /// Another app recording, screen mirroring starting, or a restriction landing. The capture is
    /// over either way, and the publication has to go with it.
    func screenRecorderDidChangeAvailability(_ screenRecorder: RPScreenRecorder) {
        guard !screenRecorder.isAvailable else { return }
        handlers.withLock(\.onUnavailable)?()
    }
}

/// Runs its body the first time only, from any thread.
@available(iOS 18, *)
private final nonisolated class ResumeOnce: Sendable {
    private let done = Mutex(false)
    
    func perform(_ body: @Sendable () -> Void) {
        let first = done.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        if first {
            body()
        }
    }
}
