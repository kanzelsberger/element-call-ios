//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Synchronization

@available(iOS 18, *)
public nonisolated enum MatrixRTCLogLevel: Sendable {
    case error, warning, info, debug, verbose
}

/// A log record emitted by the Rust core. Delivered on a dedicated Rust thread, never the main actor.
@available(iOS 18, *)
public nonisolated struct MatrixRTCLogRecord: Sendable {
    public let level: MatrixRTCLogLevel
    /// Module path of the emitting code, e.g. `matrix_rtc_core::session`.
    public let target: String
    public let message: String
    /// Where in the Rust source the record came from, when the core knows.
    ///
    /// Forwarded because a host that has no position of its own to attribute a line to will make
    /// one up: element-x-ios was passing `target` as the file and getting the line number of its
    /// own bridge, so a line read `matrix_rtc_core::session:20` where `20` pointed into
    /// `MatrixRTCLogBridge.swift`.
    public let file: String?
    public let line: UInt32?
    /// Milliseconds since the Unix epoch, captured when the record was *emitted*. Delivery is
    /// asynchronous, so a host stamping its own receive time is stamping the wrong moment.
    public let timestampMs: UInt64
    /// The Rust thread the record was emitted on.
    public let thread: String
}

/// Routes the Rust core's tracing output into the host app's logger.
///
/// The core installs a process-wide subscriber on first use and refuses a second one, so this
/// must run once, before anything else touches the FFI — `RtcSessionManagerHandle` included.
/// Without it the core is completely silent, errors included.
@available(iOS 18, *)
public nonisolated enum MatrixRTCLogging {
    /// Leaves the per-frame media/livekit flood out while keeping SFU connection and ICE progress
    /// (reported by `livekit` at info) readable.
    public static let defaultFilter = "matrix_rtc_media=debug,matrix_rtc_livekit=debug,livekit=info,libwebrtc=warn,webrtc_sys=warn"
    
    private static let isInstalled = Mutex(false)
    
    /// Installs the log sink. Idempotent; subsequent calls are ignored as the core only takes one subscriber.
    /// - Returns: `false` if the core refused the subscriber (already installed by an earlier call).
    @discardableResult
    public static func install(filter: String = defaultFilter,
                               handler: @escaping @Sendable (MatrixRTCLogRecord) -> Void) -> Bool {
        isInstalled.withLock { isInstalled in
            guard !isInstalled else { return true }
            
            do {
                try setupLogging(config: RtcLogConfig(level: .debug, filter: filter, writeToSystem: false),
                                 sink: Sink(handler: handler))
                isInstalled = true
                return true
            } catch {
                // Ours, not the core's, so there is no Rust position to carry.
                handler(.init(level: .error,
                              target: "matrix_rtc_ffi",
                              message: "Failed installing the log sink: \(error)",
                              file: nil,
                              line: nil,
                              timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
                              thread: Thread.current.description))
                return false
            }
        }
    }
    
    private final class Sink: RtcLogSink, Sendable {
        private let handler: @Sendable (MatrixRTCLogRecord) -> Void
        
        init(handler: @escaping @Sendable (MatrixRTCLogRecord) -> Void) {
            self.handler = handler
        }
        
        func log(record: RtcLogRecord) {
            handler(.init(level: .init(record.level),
                          target: record.target,
                          message: record.message,
                          file: record.file,
                          line: record.line,
                          timestampMs: record.timestampMs,
                          thread: record.thread))
        }
    }
}

@available(iOS 18, *)
private nonisolated extension MatrixRTCLogLevel {
    init(_ level: RtcLogLevel) {
        switch level {
        case .error: self = .error
        case .warn: self = .warning
        case .info: self = .info
        case .debug: self = .debug
        case .trace: self = .verbose
        }
    }
}
