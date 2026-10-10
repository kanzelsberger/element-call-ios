//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Synchronization

/// Counts frames on one stream and reports the upright size with the frame rate once a second, or
/// at once when the size changes.
@available(iOS 18, *)
final nonisolated class VideoFrameMeter: Sendable {
    private struct State {
        var width = 0
        var height = 0
        var frames = 0
        var windowStart: TimeInterval = 0
    }
    
    private let state = Mutex<State>(.init())
    
    /// - Returns: the info to report, or nil when nothing changed and the second is not over yet.
    func record(_ frame: MatrixRTCVideoFrame, now: TimeInterval = Date().timeIntervalSince1970) -> MatrixRTCVideoInfo? {
        let rotated = frame.rotation == .deg90 || frame.rotation == .deg270
        let width = rotated ? frame.height : frame.width
        let height = rotated ? frame.width : frame.height
        return state.withLock { state in
            if state.windowStart == 0 {
                state.windowStart = now
            }
            state.frames += 1
            let sizeChanged = width != state.width || height != state.height
            let elapsed = now - state.windowStart
            guard sizeChanged || elapsed >= 1 else { return nil }
            let fps = elapsed > 0 ? Int((Double(state.frames) / elapsed).rounded()) : 0
            state.width = width
            state.height = height
            if elapsed >= 1 {
                state.frames = 0
                state.windowStart = now
            }
            return MatrixRTCVideoInfo(width: width, height: height, framesPerSecond: fps)
        }
    }
}
