//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Synchronization

/// One remote member's render path, as a type that cannot reach the audio engine or the sink.
///
/// Split out of ``AudioPlaybackSink`` for the same two reasons as ``MicrophoneTap``: the block gets
/// a preallocated scratch buffer instead of allocating on the real-time thread, and the render
/// logic becomes testable without an engine. The sink kept a `RenderFlags` box for the second half
/// of that already — this absorbs it.
@available(iOS 18, *)
final nonisolated class AudioPlaybackRenderer: @unchecked Sendable {
    /// Sized like ``MicrophoneTap/scratchCapacity`` and for the same reason: a larger callback is
    /// served in passes rather than truncated, so the constant costs a loop and never audio.
    static let scratchCapacity = 4096
    
    private let ring: PCMRingBuffer
    /// How much has to be buffered before playback starts, so the first under-run is not immediate.
    private let prefill: Int
    private let scratch: UnsafeMutableBufferPointer<Int16>
    
    private let isPrimed = Atomic<Bool>(false)
    private let isDetached = Atomic<Bool>(false)
    let underruns = Atomic<Int>(0)
    
    init(ring: PCMRingBuffer, prefill: Int) {
        self.ring = ring
        self.prefill = prefill
        scratch = .allocate(capacity: Self.scratchCapacity)
        scratch.initialize(repeating: 0)
    }
    
    deinit {
        scratch.deallocate()
    }
    
    /// After this the block plays silence. It stays installed until the engine detaches the node,
    /// which happens asynchronously, so the flag is what actually stops the audio.
    func detach() {
        isDetached.store(true, ordering: .relaxed)
    }
    
    /// The block handed to the engine. It captures the renderer and nothing else — in particular
    /// not the sink, so detaching while the engine runs is safe.
    var renderBlock: AVAudioSourceNodeRenderBlock {
        { [self] _, _, frameCount, audioBufferList in
            render(frameCount: frameCount, audioBufferList: audioBufferList)
        }
    }
    
    /// Runs on the real-time thread: no allocation, no locks, no engine.
    func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let first = buffers.first, let data = first.mData else { return noErr }
        let floats = data.assumingMemoryBound(to: Float.self)
        let total = Int(frameCount)
        
        if isDetached.load(ordering: .relaxed) || (!isPrimed.load(ordering: .relaxed) && ring.availableToRead < prefill) {
            for index in 0..<total {
                floats[index] = 0
            }
            return noErr
        }
        isPrimed.store(true, ordering: .relaxed)
        
        var offset = 0
        while offset < total {
            let chunk = min(Self.scratchCapacity, total - offset)
            let slice = UnsafeMutableBufferPointer(rebasing: scratch[0..<chunk])
            let real = ring.read(into: slice)
            if real < chunk {
                underruns.wrappingAdd(1, ordering: .relaxed)
                if real == 0 {
                    isPrimed.store(false, ordering: .relaxed)
                }
            }
            for index in 0..<chunk {
                floats[offset + index] = Float(scratch[index]) / Float(Int16.max)
            }
            offset += chunk
        }
        return noErr
    }
}
