//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import Foundation
import Synchronization

// Temporary: part of the widget-driver stopgap. Only needed because a widget driver is per room
// and per call while the core subscribes to to-device messages once per Matrix session.

/// Fans to-device messages from whichever room bridges are live into session-long streams.
@available(iOS 18, *)
final nonisolated class ToDeviceRelay: Sendable {
    private struct Subscriber {
        let eventTypes: Set<String>
        let continuation: AsyncStream<MatrixRTCToDeviceMessage>.Continuation
    }
    
    private let subscribers = Mutex<[UUID: Subscriber]>([:])
    
    /// Messages of the given types for as long as the stream is iterated, whichever bridge delivers them.
    func subscribe(eventTypes: [String]) -> AsyncStream<MatrixRTCToDeviceMessage> {
        let (stream, continuation) = AsyncStream<MatrixRTCToDeviceMessage>.makeStream()
        let id = UUID()
        subscribers.withLock { $0[id] = Subscriber(eventTypes: Set(eventTypes), continuation: continuation) }
        continuation.onTermination = { [weak self] _ in
            self?.subscribers.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }
    
    func publish(_ message: MatrixRTCToDeviceMessage) {
        let continuations = subscribers.withLock { subscribers in
            subscribers.values.filter { $0.eventTypes.contains(message.eventType) }.map(\.continuation)
        }
        for continuation in continuations {
            continuation.yield(message)
        }
    }
}
