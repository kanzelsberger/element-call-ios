//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import MatrixRtc
import Synchronization

/// Plays one remote member: a source node on the engine pulls from a ring that a filler task keeps
/// topped up from the decoded stream. Under-runs play silence and are counted; a full ring drops
/// the oldest audio so latency stays bounded.
@available(iOS 18, *)
final nonisolated class AudioPlaybackSink: @unchecked Sendable {
    let memberID: String
    private let engine: CallAudioEngine
    private let ring = PCMRingBuffer(capacity: AudioFormat.samplesPerFrame * 20)
    private let renderer: AudioPlaybackRenderer
    private let frameCount = Atomic<UInt64>(0)
    
    private let filler = Mutex<Task<Void, Never>?>(nil)
    private let onLevel: @Sendable (String, MatrixRTCAudioLevel) -> Void
    
    init(memberID: String, engine: CallAudioEngine, onLevel: @escaping @Sendable (String, MatrixRTCAudioLevel) -> Void) {
        self.memberID = memberID
        self.engine = engine
        self.onLevel = onLevel
        renderer = AudioPlaybackRenderer(ring: ring, prefill: AudioFormat.samplesPerFrame * 3)
    }
    
    func start(stream: AudioFrameStream) {
        // The render block captures the renderer, never the sink, so detaching while the engine
        // runs is safe.
        engine.addSourceNode(for: memberID, render: renderer.renderBlock)
        
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled, let frame = await stream.next() {
                self?.push(frame)
            }
            MatrixRTCLog.debug("Audio stream ended for \(self?.memberID ?? "?")")
        }
        filler.withLock { $0 = task }
    }
    
    func stop() {
        filler.withLock { $0?.cancel(); $0 = nil }
        // Silence first, detach second: the detach is asynchronous and the block keeps rendering
        // until the engine gets to it.
        renderer.detach()
        engine.removeSourceNode(for: memberID)
    }
    
    private func push(_ frame: FfiAudioFrame) {
        frame.data.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            if ring.availableToWrite < samples.count {
                ring.dropOldest(samples.count - ring.availableToWrite)
            }
            ring.write(samples)
            let count = frameCount.wrappingAdd(1, ordering: .relaxed).newValue
            if count % 10 == 0 {
                onLevel(memberID, .init(level: AudioLevelMeter.level(of: samples),
                                        frameCount: count,
                                        underrunCount: renderer.underruns.load(ordering: .relaxed)))
            }
        }
    }
}
