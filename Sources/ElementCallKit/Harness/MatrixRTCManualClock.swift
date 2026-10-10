//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Synchronization

/// A clock that only moves when told to, so a test can walk a call through its release linger and
/// its stats poll one frame at a time, and the example harness can scrub through a scenario.
///
/// `MatrixRTCCall` sleeps on an injected clock rather than on `Task.sleep` for exactly this: the
/// rules the layout is tested against are about *when* a stream is released relative to a scroll,
/// and a test that waited three real seconds per frame would never be run.
///
/// Sleepers are resumed in deadline order when the clock advances past them; resuming is all this
/// does, and whatever the resumed task then does runs on its own executor, so a caller that needs
/// the consequences to have landed yields afterwards. Advancing never goes backwards.
@available(iOS 18, *)
public final nonisolated class MatrixRTCManualClock: Clock, Sendable {
    public struct Instant: InstantProtocol, Sendable, Hashable, Comparable {
        public let offset: Duration
        
        public init(offset: Duration) {
            self.offset = offset
        }
        
        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }
        
        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }
        
        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }
    
    private struct Sleeper: Sendable {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }
    
    private struct State: Sendable {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
    }
    
    private let state = Mutex(State())
    
    public init() { }
    
    public var now: Instant {
        state.withLock { $0.now }
    }
    
    public var minimumResolution: Duration {
        .zero
    }
    
    /// How far the clock has been advanced since it was made. What a scenario's times are measured
    /// against, and what a recording stamps its entries with.
    public var elapsed: Duration {
        now.offset
    }
    
    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Bool, any Error> = state.withLock { state in
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    if deadline <= state.now {
                        return .success(true)
                    }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .success(false)
                }
                switch outcome {
                case .success(true): continuation.resume()
                case .success(false): break
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }
    
    /// Moves the clock forward to `instant` (never backwards) and wakes every sleeper due by then,
    /// earliest deadline first.
    public func advance(to instant: Instant) {
        let due = state.withLock { state -> [Sleeper] in
            guard instant > state.now else { return [] }
            state.now = instant
            let due = state.sleepers.filter { $0.deadline <= instant }.sorted { $0.deadline < $1.deadline }
            state.sleepers.removeAll { $0.deadline <= instant }
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
    
    public func advance(to elapsed: Duration) {
        advance(to: Instant(offset: elapsed))
    }
    
    public func advance(by duration: Duration) {
        advance(to: now.advanced(by: duration))
    }
}
