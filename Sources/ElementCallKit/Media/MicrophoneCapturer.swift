//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import MatrixRtc
import Synchronization

/// Pulls the microphone off the engine's real-time thread, converts it to 48 kHz mono Int16 and
/// hands exactly 480-sample frames to the published track.
///
/// Muting stops handing frames over **and** tells the transport (done by the call); the engine and
/// the capture stay up so unmuting is instant.
@available(iOS 18, *)
final nonisolated class MicrophoneCapturer: @unchecked Sendable {
    private let engine: CallAudioEngine
    private let ring = PCMRingBuffer(capacity: AudioFormat.samplesPerFrame * 50)
    private let isMuted = Atomic<Bool>(false)
    private let onLevel: @Sendable (MatrixRTCAudioLevel) -> Void
    
    private let tap: MicrophoneTap
    
    private let state = Mutex<State>(.init())
    
    private struct State {
        var track: FfiLocalTrack?
        var drainer: Task<Void, Never>?
        var frameCount: UInt64 = 0
        var reportedOversizedCallbacks = 0
    }
    
    init(engine: CallAudioEngine, onLevel: @escaping @Sendable (MatrixRTCAudioLevel) -> Void) {
        self.engine = engine
        self.onLevel = onLevel
        tap = MicrophoneTap(ring: ring, format: engine.inputFormat)
    }
    
    func start(track: FfiLocalTrack) {
        stop()
        tap.resume()
        state.withLock { $0.track = track }
        
        // Converts to Int16 mono at the hardware rate on the render thread, then the drainer
        // resamples to 48 kHz. The conversion lives in MicrophoneTap so that the block provably
        // cannot reach the engine.
        engine.installInputSink(tap.receiverBlock)
        
        let drainer = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await drain()
        }
        state.withLock { $0.drainer = drainer }
    }
    
    func stop() {
        // Flag first, then clear: the tap writes from the render thread, and PCMRingBuffer is
        // single-producer/single-consumer, so `clear()` moving the read index while a write is in
        // flight is only safe once the tap has agreed to stop writing. The node itself is detached
        // by the engine, asynchronously, and its block keeps firing until then.
        tap.stop()
        engine.removeInputSink()
        let drainer = state.withLock { state -> Task<Void, Never>? in
            defer { state.drainer = nil; state.track = nil }
            return state.drainer
        }
        drainer?.cancel()
        ring.clear()
    }
    
    func setMuted(_ muted: Bool) {
        isMuted.store(muted, ordering: .relaxed)
    }
    
    // MARK: - Private
    
    /// Resamples whatever the hardware produced into 480-sample 48 kHz frames and pushes them.
    private func drain() async {
        var pending = [Int16]()
        var frame = Data(count: AudioFormat.bytesPerFrame)
        
        while !Task.isCancelled {
            let available = ring.availableToRead
            if available < 64 {
                try? await Task.sleep(for: .milliseconds(5))
                continue
            }
            
            var chunk = [Int16](repeating: 0, count: available)
            chunk.withUnsafeMutableBufferPointer { ring.read(into: $0) }
            pending += resampleToTarget(chunk)
            
            while pending.count >= AudioFormat.samplesPerFrame {
                var samples = Array(pending.prefix(AudioFormat.samplesPerFrame))
                pending.removeFirst(AudioFormat.samplesPerFrame)
                
                // Meter before the mute check: knowing the microphone is alive while muted is exactly
                // the question a silent call raises.
                let level = samples.withUnsafeBufferPointer { AudioLevelMeter.level(of: $0) }
                let count = state.withLock { state -> UInt64 in
                    state.frameCount += 1
                    return state.frameCount
                }
                if count % 10 == 0 {
                    onLevel(.init(level: level, frameCount: count, underrunCount: nil))
                }
                
                guard !isMuted.load(ordering: .relaxed), let track = state.withLock({ $0.track }) else { continue }
                
                frame.withUnsafeMutableBytes { bytes in
                    bytes.copyBytes(from: samples.withUnsafeBufferPointer { UnsafeRawBufferPointer($0) })
                }
                do {
                    try await track.captureAudio(frame: FfiAudioFrame(data: frame,
                                                                      sampleRate: UInt32(AudioFormat.sampleRate),
                                                                      numChannels: UInt32(AudioFormat.channelCount),
                                                                      samplesPerChannel: UInt32(AudioFormat.samplesPerFrame)))
                } catch {
                    MatrixRTCLog.warning("captureAudio failed: \(error)")
                }
            }
            reportOversizedCallbacks()
        }
    }
    
    /// The tap counts these but cannot log them: logging from the IO thread allocates and takes
    /// locks. Reported once per new occurrence so a wrong `scratchCapacity` shows up in a real log
    /// rather than staying a guess.
    private func reportOversizedCallbacks() {
        let total = tap.oversizedCallbacks.load(ordering: .relaxed)
        let unreported = state.withLock { state -> Int in
            defer { state.reportedOversizedCallbacks = total }
            return total - state.reportedOversizedCallbacks
        }
        if unreported > 0 {
            MatrixRTCLog.warning("Microphone callback exceeded \(MicrophoneTap.scratchCapacity) frames \(unreported) time(s)")
        }
    }
    
    /// Linear resampling from the hardware rate to 48 kHz; the hardware usually *is* 48 kHz, in
    /// which case this is a copy.
    private func resampleToTarget(_ samples: [Int16]) -> [Int16] {
        let inputRate = engine.inputFormat.value.sampleRate
        guard inputRate > 0, Int(inputRate) != AudioFormat.sampleRate else { return samples }
        let ratio = inputRate / Double(AudioFormat.sampleRate)
        let outputCount = Int(Double(samples.count) / ratio)
        var output = [Int16](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let position = Double(index) * ratio
            let lower = Int(position)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            output[index] = Int16(Float(samples[lower]) * (1 - fraction) + Float(samples[upper]) * fraction)
        }
        return output
    }
}
