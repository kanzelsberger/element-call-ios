//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import Foundation
import MatrixRustSDK

// How a failure is classified matters more than it looks. `notSupported` makes the core retire the
// feature for the whole session; `failed` makes it retry. Get them the wrong way round and a call
// either silently stops using delayed events, or hammers a homeserver that will never say yes.

// Both extensions are `nonisolated` because the module default is `MainActor` and these are pure
// switches over values with no reason to need it. It also lets the tests that exercise them run off
// the main actor, which is what stopped them being billed for time the snapshot tests spent holding
// it -- a two-line comparison below was reported taking 68 seconds on CI, all of it queueing.
@available(iOS 18, *)
nonisolated extension MatrixRTCRoomBridgeError {
    /// A permanent refusal retires the feature; anything else is retried.
    ///
    /// A 404 with `M_UNRECOGNIZED` means the homeserver does not implement the endpoint. matrix.org
    /// instead answers 403 with "Sending delayed events has been disallowed", which only the message
    /// separates from a genuine power-level rejection, and a power-level rejection would clear the
    /// moment our power level changed, so it must stay retryable.
    var transportError: MatrixRTCTransportError {
        switch self {
        case .matrixAPI(let errcode, _, let message):
            if errcode == "M_UNRECOGNIZED" {
                return .notSupported(message)
            }
            if errcode == "M_FORBIDDEN", message.localizedCaseInsensitiveContains("delayed event") {
                return .notSupported(message)
            }
            return .failed(message)
        case .notRunning, .timedOut, .invalidResponse:
            return .failed("\(self)")
        }
    }
}

@available(iOS 18, *)
extension Result where Failure == MatrixRTCRoomBridgeError {
    func mapTransportError() throws -> Success {
        switch self {
        case .success(let value): value
        case .failure(let error): throw error.transportError
        }
    }
}

@available(iOS 18, *)
nonisolated extension Error {
    /// The same classification for failures that come straight off the SDK rather than the bridge.
    var transportError: MatrixRTCTransportError {
        if let clientError = self as? ClientError, case .MatrixApi(let kind, _, let message, _) = clientError {
            switch kind {
            case .unrecognized:
                return .notSupported(message)
            case .forbidden where message.localizedCaseInsensitiveContains("delayed event"):
                return .notSupported(message)
            default:
                break
            }
        }
        return .failed("\(self)")
    }
}
