//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Synchronization

/// The latest frame for one renderer. Overwriting releases the previous frame (dropping is the
/// normal case under load, and must never become back-pressure on the decoder or a leak).
@available(iOS 18, *)
public final nonisolated class VideoFrameSlot: Sendable, Identifiable {
    public let id = UUID()
    /// Boxed on purpose: a function value kept directly in a generic `Mutex` is reabstracted on
    /// every `withLock` and written back wrapped in one more thunk, so the stored closure grew by
    /// two frames per offered video frame until invoking or releasing it overflowed the stack.
    private struct FrameHandler {
        let call: @Sendable () -> Void
    }
    
    private let latest = Mutex<MatrixRTCVideoFrame?>(nil)
    private let onFrame = Mutex<FrameHandler?>(nil)
    private let firstFrame = Mutex<FrameHandler?>(nil)
    private let hasFrame = Atomic<Bool>(false)
    
    /// Whether this slot has ever been offered a frame since the last ``clear()``.
    ///
    /// A tile draws video when the roster says the member publishes a camera, which is a claim
    /// about signalling rather than about pixels. When the two disagree — the roster is stale, or
    /// the far end publishes a track it never sends on — the tile used to be a black rectangle
    /// with nothing to explain it. This is how a surface knows to keep showing the avatar.
    public var hasReceivedFrame: Bool {
        hasFrame.load(ordering: .relaxed)
    }
    
    public init() { }
    
    public func offer(_ frame: MatrixRTCVideoFrame) {
        latest.withLock { $0 = frame }
        // Fired once per clear, off the render path after the first frame: the exchange is what
        // makes it once, so a surface can swap the avatar out without polling.
        if !hasFrame.exchange(true, ordering: .relaxed) {
            firstFrame.withLock { $0 }?.call()
        }
        onFrame.withLock { $0 }?.call()
    }
    
    /// Called on the offering thread the first time a frame arrives, and again after a ``clear()``.
    /// Separate from ``setOnFrame(_:)``, which the renderer owns.
    public func setOnFirstFrame(_ handler: (@Sendable () -> Void)?) {
        let boxed = handler.map(FrameHandler.init)
        firstFrame.withLock { $0 = boxed }
    }
    
    /// Takes the pending frame, leaving the slot empty.
    public func take() -> MatrixRTCVideoFrame? {
        latest.withLock { frame in
            defer { frame = nil }
            return frame
        }
    }
    
    /// Called on the offering thread whenever a frame arrives; renderers use it to request a draw.
    public func setOnFrame(_ handler: (@Sendable () -> Void)?) {
        let boxed = handler.map(FrameHandler.init)
        onFrame.withLock { $0 = boxed }
    }
    
    public func clear() {
        latest.withLock { $0 = nil }
        // A slot is reused when its tile changes member, so the next stream has to earn its
        // first frame again rather than inheriting the previous one's.
        hasFrame.store(false, ordering: .relaxed)
    }
}

/// One decoding stream per `(member, kind)`, fanned out to every tile drawing it.
///
/// Opening the stream is what makes the core decode at all, so a stream nobody draws costs
/// nothing. Two handles on one track crash the core, hence exactly one per key, and a linger before
/// closing: SwiftUI disposes the old tile before creating the new one when a member moves between
/// spotlight and strip, and tearing the stream down in that gap raced a frame in flight.
@available(iOS 18, *)
final nonisolated class RemoteVideoSource: @unchecked Sendable {
    static let linger: Duration = .seconds(2)
    
    private let open: @Sendable () -> VideoFrameStreamBox?
    /// Called when the last tile has gone and the linger elapsed: nobody is drawing this stream.
    private let onIdle: @Sendable () -> Void
    /// What the linger runs on: the call's clock, so a scenario can step past it. The fifth timer
    /// the harness has to own, and the one the plan's list missed because it lives here rather
    /// than on the call.
    private let clock: any Clock<Duration>
    /// The upright size and frame rate of the decoded frames, about once a second.
    var onVideoInfo: (@Sendable (MatrixRTCVideoInfo) -> Void)?
    private let meter = VideoFrameMeter()
    private let state = Mutex<State>(.init())
    
    private struct State {
        var slots = [UUID: VideoFrameSlot]()
        var reader: Task<Void, Never>?
        var lingerTask: Task<Void, Never>?
    }
    
    init(open: @escaping @Sendable () -> VideoFrameStreamBox?,
         onIdle: @escaping @Sendable () -> Void,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.open = open
        self.onIdle = onIdle
        self.clock = clock
    }
    
    func attach(_ slot: VideoFrameSlot) {
        state.withLock { state in
            state.slots[slot.id] = slot
            state.lingerTask?.cancel()
            state.lingerTask = nil
            if state.reader == nil {
                state.reader = startReader()
            }
        }
    }
    
    func detach(_ slot: VideoFrameSlot) {
        state.withLock { state in
            state.slots[slot.id] = nil
            slot.clear()
            guard state.slots.isEmpty, state.lingerTask == nil else { return }
            let clock = clock
            state.lingerTask = Task { [weak self] in
                try? await clock.sleep(for: Self.linger)
                guard !Task.isCancelled else { return }
                self?.closeIfIdle()
            }
        }
    }
    
    func close() {
        state.withLock { state in
            state.reader?.cancel()
            state.reader = nil
            state.lingerTask?.cancel()
            state.lingerTask = nil
            state.slots.values.forEach { $0.clear() }
            state.slots.removeAll()
        }
    }
    
    /// Nobody is drawing: stop asking the SFU for frames, but keep the reader. The FFI stream has no
    /// `close()` and `next()` cannot be cancelled, so a reader parked on a quiet stream would stay
    /// alive, and opening a second stream on the same track crashes the core. Reattaching reuses it.
    private func closeIfIdle() {
        let idle = state.withLock { state -> Bool in
            guard state.slots.isEmpty else { return false }
            state.lingerTask = nil
            return true
        }
        if idle {
            onIdle()
        }
    }
    
    private func reportAspect(of frame: MatrixRTCVideoFrame) {
        if let info = meter.record(frame) {
            onVideoInfo?(info)
        }
    }
    
    private func startReader() -> Task<Void, Never> {
        let open = open
        return Task.detached(priority: .userInitiated) { [weak self] in
            guard let stream = open() else {
                MatrixRTCLog.warning("No video stream to open")
                return
            }
            defer { stream.close() }
            while !Task.isCancelled, let ref = await stream.next() {
                guard let self else { return }
                let frame = MatrixRTCVideoFrame(ref: ref)
                reportAspect(of: frame)
                let slots = state.withLock { Array($0.slots.values) }
                // Every slot holds its own reference; the frame is freed once the last one drops it.
                for slot in slots {
                    slot.offer(frame)
                }
            }
        }
    }
}

/// Wraps the FFI stream so the reader can close it explicitly when cancelled.
@available(iOS 18, *)
final nonisolated class VideoFrameStreamBox: @unchecked Sendable {
    private let stream: MatrixRtc.VideoFrameStream
    
    init(_ stream: MatrixRtc.VideoFrameStream) {
        self.stream = stream
    }
    
    func next() async -> MatrixRtc.VideoFrameRef? {
        await stream.next()
    }
    
    func close() {
        // Dropping the last reference closes the stream on the Rust side.
    }
}
