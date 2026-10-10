//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Synchronization

/// Everything the microphone sink block does, as a type that **cannot reach the audio engine**.
///
/// That is the whole point, and the initialiser is where it is enforced: a tap is built from a ring
/// and a format snapshot and nothing else. An earlier version read `engine.inputFormat` from inside
/// the block, which took `AVAudioEngine`'s mutex on the real-time thread and deadlocked hang-up
/// against `detach` (see ``InputStreamFormat``). If a change ever hands this type an engine to ask,
/// `MicrophoneTapTests` stops compiling, which is the point of writing the test against the
/// initialiser.
@available(iOS 18, *)
final nonisolated class MicrophoneTap: @unchecked Sendable {
    /// The IO unit's default `maximumFramesToRender`, against the 480 (10 ms at 48 kHz) the session
    /// asks for. This is a sizing choice, not a limit: ``render(frameCount:audioBufferList:)``
    /// converts a larger callback in passes, so an unexpected value costs a second loop rather than
    /// dropped audio.
    static let scratchCapacity = 4096
    
    private let ring: PCMRingBuffer
    private let format: InputFormatSnapshot
    private let scratch: UnsafeMutableBufferPointer<Int16>
    private let isStopped = Atomic<Bool>(false)
    
    /// Counted here and reported by the drainer. Logging from the IO thread allocates and takes
    /// locks, so the render path can never log its own anomalies.
    let oversizedCallbacks = Atomic<Int>(0)
    
    init(ring: PCMRingBuffer, format: InputFormatSnapshot) {
        self.ring = ring
        self.format = format
        scratch = .allocate(capacity: Self.scratchCapacity)
        scratch.initialize(repeating: 0)
    }
    
    deinit {
        scratch.deallocate()
    }
    
    /// After this the block still runs — the engine detaches the node asynchronously — but writes
    /// nothing, so audio captured after a hang-up never reaches the ring.
    func stop() {
        isStopped.store(true, ordering: .relaxed)
    }
    
    func resume() {
        isStopped.store(false, ordering: .relaxed)
    }
    
    /// The block handed to the engine. It captures the tap strongly and deliberately: the node
    /// keeps the block alive past ``MicrophoneCapturer``'s release of the tap, and the scratch
    /// buffer must outlive the last callback.
    var receiverBlock: AVAudioSinkNodeReceiverBlock {
        { [self] _, frameCount, audioBufferList in
            render(frameCount: frameCount, audioBufferList: audioBufferList)
        }
    }
    
    /// Runs on the real-time thread: no allocation, no locks, no engine.
    func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafePointer<AudioBufferList>) -> OSStatus {
        guard !isStopped.load(ordering: .relaxed) else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        guard let first = buffers.first, let data = first.mData else { return noErr }
        
        let format = format.value
        // 0 Hz means the session is not active yet, so there is no rate to resample from later.
        guard format.sampleRate > 0 else { return noErr }
        
        let floats = data.assumingMemoryBound(to: Float.self)
        let total = Int(frameCount)
        if total > Self.scratchCapacity {
            oversizedCallbacks.wrappingAdd(1, ordering: .relaxed)
        }
        
        var offset = 0
        while offset < total {
            let chunk = min(Self.scratchCapacity, total - offset)
            for index in 0..<chunk {
                let source = offset + index
                // Hardware input is Float32; take channel 0 when it is stereo.
                let sample = format.isInterleaved ? floats[source * format.channelCount] : floats[source]
                // Clamp order matters: `min(1, .nan)` yields 1 in Swift, so a NaN sample saturates
                // instead of trapping `Int16.init` on the IO thread. Rewriting this as a
                // `clamped(to:)` helper would reintroduce that trap.
                scratch[index] = Int16(max(-1, min(1, sample)) * Float(Int16.max))
            }
            ring.write(UnsafeBufferPointer(UnsafeMutableBufferPointer(rebasing: scratch[0..<chunk])))
            offset += chunk
        }
        return noErr
    }
}
