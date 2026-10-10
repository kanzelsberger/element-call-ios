//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import Foundation
import MatrixRustSDK

/// Opens a widget driver for a room and wraps it in a bridge.
///
/// This is the only part of the widget stopgap that touches the SDK. The bridge itself speaks the
/// widget API's JSON to a channel, which is why its tests can drive it through a pair of pipes with
/// no SDK and no homeserver in sight.
@available(iOS 18, *)
enum WidgetDriverFactory {
    static func makeBridge(room: Room,
                           roomID: String,
                           logger: (any ElementCallLoggingProtocol)?) -> (any MatrixRTCRoomBridgeProtocol)? {
        let widgetID = UUID().uuidString
        // Negotiation starts at `run()` rather than on a `content_loaded` that no web view will send;
        // the URL only has to parse, nothing loads it.
        let settings = WidgetSettings(widgetId: widgetID, initAfterContentLoad: false, rawUrl: "https://call.element.io/")
        
        let driverAndHandle: WidgetDriverAndHandle
        do {
            driverAndHandle = try makeWidgetDriver(settings: settings)
        } catch {
            logger?.log(.error, "cannot make a widget driver for \(roomID): \(error)")
            return nil
        }
        
        // The closure must not hold the handle: the driver only stops once the handle is released.
        let driver = driverAndHandle.driver
        let grant = WidgetCapabilityGrant()
        return WidgetMatrixBridge(roomID: roomID,
                                  widgetID: widgetID,
                                  channel: driverAndHandle.handle,
                                  logger: logger) {
            await driver.run(room: room, capabilitiesProvider: grant)
        }
    }
}
