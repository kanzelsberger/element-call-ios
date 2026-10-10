//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import Foundation

@available(iOS 18, *)
nonisolated enum MatrixRTCRoomBridgeError: Error, Sendable, Equatable {
    /// The bridge is not (or no longer) running for the room.
    case notRunning
    case timedOut
    /// The bridge answered, but not with what the operation needs.
    case invalidResponse(String)
    /// The homeserver refused the request; `errcode` when the bridge could tell.
    case matrixAPI(errcode: String?, httpStatus: Int?, message: String)
}

/// Exactly the Matrix operations the released SDK bindings do not expose yet for a room: delayed
/// events, room event IDs, the room-state feed and to-device messaging. `ElementCallSDKTransport`
/// routes those through whatever implements this; everything else goes straight to the SDK.
///
/// Today's implementation is `WidgetMatrixBridge`, driving the SDK widget driver in process. See that
/// file's header for the exact bindings that retire this. Once they land, an SDK-backed
/// implementation replaces it and the transport does not change.
@available(iOS 18, *)
nonisolated protocol MatrixRTCRoomBridgeProtocol: AnyObject, Sendable {
    var roomID: String { get }
    
    /// Returns once the bridge can serve requests.
    func start() async -> Result<Void, MatrixRTCRoomBridgeError>
    func stop() async
    
    /// - Returns: the MSC4140 delay ID.
    func sendDelayedEvent(eventType: String, stateKey: String?, contentJSON: String, delayMs: UInt64) async -> Result<String, MatrixRTCRoomBridgeError>
    func updateDelayedEvent(delayID: String, action: MatrixRTCDelayedEventAction) async -> Result<Void, MatrixRTCRoomBridgeError>
    /// - Returns: the event ID.
    func sendRoomEvent(eventType: String, contentJSON: String) async -> Result<String, MatrixRTCRoomBridgeError>
    /// The transports the homeserver advertises, over MSC4515. Homeserver-wide despite arriving
    /// through a room's driver, which just forwards to `Client::discover_rtc_transports`.
    func rtcTransports() async -> Result<[MatrixRTCTransport], MatrixRTCRoomBridgeError>
    /// `messages` is user ID → device ID → content JSON.
    /// - Returns: the recipients that were **not** served, user ID → device IDs.
    func sendToDeviceMessage(eventType: String, messages: [String: [String: String]]) async -> Result<[String: [String]], MatrixRTCRoomBridgeError>
    
    /// The full current list of state events of that type, immediately when there are any, and on every change.
    func stateEvents(eventType: String) -> AsyncStream<[MatrixRTCRoomStateEvent]>
    /// Every to-device message the bridge is allowed to receive, for as long as it runs.
    func toDeviceMessages() -> AsyncStream<MatrixRTCToDeviceMessage>
}
