//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

public nonisolated enum ElementCallLogLevel: Sendable {
    case debug, info, warning, error
}

/// Where our log lines go. The host owns this so call logs land in the same place, and the same
/// rageshake, as everything else it writes.
///
/// Note this covers only this package's own lines. The media layer's logs, and the Rust core's, go
/// through the core's own subscriber, which the host installs separately.
/// One of our own log lines, with the position it came from.
public nonisolated struct ElementCallLogRecord: Sendable {
    public let level: ElementCallLogLevel
    public let message: String
    /// `#fileID` of the call site, e.g. `ElementCall/ElementCallController.swift`.
    public let file: String
    public let line: Int
    
    public init(level: ElementCallLogLevel, message: String, file: String, line: Int) {
        self.level = level
        self.message = message
        self.file = file
        self.line = line
    }
}

public nonisolated protocol ElementCallLoggingProtocol: Sendable {
    /// The one method a host implements.
    ///
    /// Takes a record rather than `(level, message, file, line)` because the convenience below
    /// needs `#fileID` and `#line` defaults, and Swift does not allow default arguments on a
    /// protocol requirement — an extension with the same signature would become the requirement's
    /// own default implementation and recurse forever on a host that did not override it.
    func log(_ record: ElementCallLogRecord)
}

public nonisolated extension ElementCallLoggingProtocol {
    /// What everything in this package calls. The defaults make the call site attribute itself,
    /// so a host formatting a line with a position gets our source rather than its own bridge.
    func log(_ level: ElementCallLogLevel, _ message: String, file: String = #fileID, line: Int = #line) {
        log(ElementCallLogRecord(level: level, message: message, file: file, line: line))
    }
}
