//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Synchronization

/// The part of an `AVAudioFormat` the microphone render path actually needs, as a value.
///
/// The render block used to ask the engine for this, and that question is what deadlocked hang-up:
/// the IO thread held the render graph and waited on `AVAudioEngine`'s own mutex, while the main
/// thread held that mutex (detaching a playback node) and waited on the graph. Nothing reachable
/// from the render thread may call into `AVAudioEngine`, so the format is *pushed* to it through
/// ``InputFormatSnapshot`` rather than pulled.
@available(iOS 18, *)
nonisolated struct InputStreamFormat: Sendable, Equatable {
    /// Never zero. The render path strides by it, so a hardware format that has not been read yet
    /// has to produce a harmless mono read rather than a stride of zero.
    let channelCount: Int
    let isInterleaved: Bool
    /// Zero until the audio session is active — the input node genuinely reports 0 Hz before then,
    /// and audio arriving at an unknown rate is dropped rather than resampled by a guess.
    let sampleRate: Double
}

@available(iOS 18, *)
nonisolated extension InputStreamFormat {
    static let unknown = InputStreamFormat(channelCount: 1, isInterleaved: false, sampleRate: 0)
    
    init(_ format: AVAudioFormat) {
        self.init(channelCount: Int(format.channelCount),
                  isInterleaved: format.isInterleaved,
                  sampleRate: format.sampleRate)
    }
    
    /// Whether a graph can actually be built against this format.
    ///
    /// `AVAudioEngine.connect(_:to:format:)` with a nil format adopts whatever the node reports,
    /// and on an inactive audio session that is 0 Hz. AVFAudio then fails the bus's `setFormat:`
    /// with `kAudioUnitErr_FormatNotSupported` (-10868) and raises an **Objective-C exception**,
    /// which Swift cannot catch, so the process dies rather than degrading. There is no throwing
    /// form of `connect`, so the only defence is to ask first.
    ///
    /// Reached on an iOS app running on macOS, where CallKit never activates the session and so
    /// nothing ever makes the format real; also reachable on iOS proper if the microphone is
    /// published before activation arrives.
    var isUsable: Bool {
        sampleRate > 0 && channelCount > 0
    }
    
    /// All three fields in one word, so a reader cannot see a new channel count against a stale
    /// interleaved flag. Three separate atomics would tear, and that particular tear indexes out of
    /// bounds on the render thread.
    ///
    /// The rate is stored as `Float` rather than an integer count of Hz: every rate we see is exact
    /// either way, but some routes report a fractional rate and rounding it would bias the
    /// resampler rather than fail loudly.
    var packed: UInt64 {
        UInt64(Float(sampleRate).bitPattern)
            | UInt64(UInt8(clamping: channelCount)) << 32
            | (isInterleaved ? 1 << 40 : 0)
    }
    
    init(packed: UInt64) {
        sampleRate = Double(Float(bitPattern: UInt32(truncatingIfNeeded: packed)))
        channelCount = max(1, Int(UInt8(truncatingIfNeeded: packed >> 32)))
        isInterleaved = packed & (1 << 40) != 0
    }
}

/// Written by ``CallAudioEngine`` whenever it starts or re-attaches the sink, read once per render
/// callback. One relaxed atomic load is the entire cost on the real-time thread.
@available(iOS 18, *)
final nonisolated class InputFormatSnapshot: Sendable {
    private let word = Atomic<UInt64>(InputStreamFormat.unknown.packed)
    
    var value: InputStreamFormat {
        .init(packed: word.load(ordering: .relaxed))
    }
    
    func store(_ format: InputStreamFormat) {
        word.store(format.packed, ordering: .relaxed)
    }
}
