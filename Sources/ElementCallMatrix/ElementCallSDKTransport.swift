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

/// The Matrix side of a call, over the Rust SDK. A host builds one of these with its `Client` and
/// hands it to ``ElementCallStack``; there is nothing else for it to implement.
///
/// Main-actor bound, because the SDK's room and client objects are, and because the core awaits
/// every send. The feeds hop onto the main actor inside their streams.
///
/// What the released bindings do not expose yet, delayed events, the room-state feed, to-device
/// messaging and room event IDs, goes through a per-room ``MatrixRTCRoomBridgeProtocol``, opened in
/// ``willJoinRoom(roomID:)`` and closed in ``didLeaveRoom(roomID:)``. See `Widget/` for what retires
/// that, and note that MSC4515 transport discovery already came off the stopgap list.
@MainActor
@available(iOS 18, *)
public final class ElementCallSDKTransport: ElementCallMatrixTransportProtocol {
    public nonisolated let userID: String
    public nonisolated let deviceID: String
    
    private let client: Client
    private let logger: (any ElementCallLoggingProtocol)?
    private var liveBridges = [String: LiveBridge]()
    /// The core subscribes once per session; bridges come and go with calls.
    private nonisolated let toDeviceRelay = ToDeviceRelay()
    
    public init?(client: Client, logger: (any ElementCallLoggingProtocol)? = nil) {
        guard let userID = try? client.userId(), let deviceID = try? client.deviceId() else {
            logger?.log(.error, "no user or device ID, cannot serve a call")
            return nil
        }
        self.client = client
        self.logger = logger
        self.userID = userID
        self.deviceID = deviceID
    }
    
    // MARK: - Lifecycle
    
    public nonisolated func willJoinRoom(roomID: String) async throws {
        try await onMain { transport in
            _ = try await transport.openBridge(roomID: roomID)
        }
    }
    
    public nonisolated func didLeaveRoom(roomID: String) async {
        let live = await Task { @MainActor in liveBridges.removeValue(forKey: roomID) }.value
        live?.toDeviceForwarder.cancel()
        await live?.bridge.stop()
    }
    
    /// A bridge and the task pumping its to-device messages into the relay, kept together so they
    /// cannot exist apart.
    ///
    /// They were separate dictionaries once, and that cost an afternoon. A bridge is opened either
    /// by `willJoinRoom` or, earlier, by transport discovery, and the version that only started the
    /// pump in `willJoinRoom` skipped it whenever discovery had already opened one. Media keys then
    /// arrived at the bridge and reached nobody, so no participant's frames decrypted and every
    /// remote tile was black with `missingKey` in its stats. Audio survived because it is keyed the
    /// same way but far more forgiving of a late key.
    private struct LiveBridge {
        let bridge: any MatrixRTCRoomBridgeProtocol
        let toDeviceForwarder: Task<Void, Never>
    }
    
    /// The only place a bridge is created, so everything a bridge needs is wired in one spot.
    /// Opened on demand rather than only in `willJoinRoom`, because transport discovery is asked
    /// before the room is prepared and routes through the driver.
    private func openBridge(roomID: String) async throws -> any MatrixRTCRoomBridgeProtocol {
        if let live = liveBridges[roomID] {
            return live.bridge
        }
        guard let bridge = try WidgetDriverFactory.makeBridge(room: room(roomID), roomID: roomID, logger: logger) else {
            throw MatrixRTCTransportError.failed("Cannot open a Matrix bridge for \(roomID)")
        }
        if case .failure(let error) = await bridge.start() {
            throw error.transportError
        }
        
        let forwarder = Task { [relay = toDeviceRelay] in
            for await message in bridge.toDeviceMessages() {
                relay.publish(message)
            }
        }
        liveBridges[roomID] = LiveBridge(bridge: bridge, toDeviceForwarder: forwarder)
        return bridge
    }
    
    // MARK: - Discovery
    
    public nonisolated func rtcTransports(roomID: String) async throws -> [MatrixRTCTransport] {
        try await onMain { transport in
            // Homeserver-wide, but MSC4515 is served per room by the driver, so a bridge has to
            // exist. Cached under the room, and `willJoinRoom` will find it already open.
            let bridge = try await transport.openBridge(roomID: roomID)
            return try await bridge.rtcTransports().mapTransportError()
        }
    }
    
    // MARK: - Sends
    
    // Every witness is nonisolated, since async protocol requirements run on the caller, so each
    // hops onto the main actor where the SDK objects live.
    
    public nonisolated func sendStateEvent(roomID: String, eventType: String, stateKey: String, contentJSON: String) async throws -> String {
        try await onMain { transport in
            try await transport.sdkCall("sendStateEventRaw(\(eventType))", in: roomID) { room in
                try await room.sendStateEventRaw(eventType: eventType, stateKey: stateKey, content: contentJSON)
            }
        }
    }
    
    /// Sticky events (MSC4354) need bindings the released SDK lacks, so only the state-event
    /// compatibility mode can be joined, and that never sends one.
    public nonisolated func sendStickyEvent(roomID: String, eventType: String, contentJSON: String, durationMs: UInt64) async throws -> String {
        throw MatrixRTCTransportError.notSupported("Sticky events are not available with the released SDK")
    }
    
    public nonisolated func sendDelayedEvent(roomID: String, eventType: String, contentJSON: String, delayMs: UInt64) async throws -> String {
        try await bridge(roomID).sendDelayedEvent(eventType: eventType, stateKey: nil, contentJSON: contentJSON, delayMs: delayMs).mapTransportError()
    }
    
    public nonisolated func sendDelayedStateEvent(roomID: String, eventType: String, stateKey: String, contentJSON: String, delayMs: UInt64) async throws -> String {
        try await bridge(roomID).sendDelayedEvent(eventType: eventType, stateKey: stateKey, contentJSON: contentJSON, delayMs: delayMs).mapTransportError()
    }
    
    public nonisolated func updateDelayedEvent(roomID: String, delayID: String, action: MatrixRTCDelayedEventAction) async throws {
        try await bridge(roomID).updateDelayedEvent(delayID: delayID, action: action).mapTransportError()
    }
    
    /// The core does not say which room the keys are for, and the bridge does not need it either: it
    /// encrypts whenever its room is encrypted. Only one call runs at a time.
    public nonisolated func sendToDeviceMessage(eventType: String, messages: [String: [String: String]]) async throws -> [String: [String]] {
        let bridge = try await onMain { transport -> any MatrixRTCRoomBridgeProtocol in
            if transport.liveBridges.count > 1 {
                transport.logger?.log(.warning, "\(transport.liveBridges.count) live bridges, sending to-device through the first")
            }
            guard let bridge = transport.liveBridges.values.first?.bridge else {
                throw MatrixRTCTransportError.failed("No live call to send to-device messages through")
            }
            return bridge
        }
        return try await bridge.sendToDeviceMessage(eventType: eventType, messages: messages).mapTransportError()
    }
    
    /// Both transport paths report the event ID so callers can track or redact what they sent.
    public nonisolated func sendRoomEvent(roomID: String, eventType: String, contentJSON: String) async throws -> String {
        if let bridge = await liveBridge(roomID) {
            return try await bridge.sendRoomEvent(eventType: eventType, contentJSON: contentJSON).mapTransportError()
        }
        return try await onMain { transport in
            try await transport.sdkCall("sendRaw(\(eventType))", in: roomID) { room in
                try await room.sendRaw(eventType: eventType, content: contentJSON)
            }
        }
    }
    
    public nonisolated func redactEvent(roomID: String, eventID: String, reason: String?) async throws {
        try await onMain { transport in
            try await transport.sdkCall("redact", in: roomID) { room in
                try await room.redact(eventId: eventID, reason: reason)
            }
        }
    }
    
    public nonisolated func requestOpenIDToken() async throws -> MatrixRTCOpenIDToken {
        let token = try await onMain { transport -> OpenIdToken in
            do {
                return try await transport.client.requestOpenidToken()
            } catch {
                throw error.transportError
            }
        }
        return MatrixRTCOpenIDToken(accessToken: token.accessToken,
                                    tokenType: token.tokenType,
                                    matrixServerName: token.matrixServerName,
                                    expiresIn: TimeInterval(token.expiresInSeconds))
    }
    
    // MARK: - Feeds
    
    public nonisolated func toDeviceMessages(eventTypes: [String]) -> AsyncStream<MatrixRTCToDeviceMessage> {
        toDeviceRelay.subscribe(eventTypes: eventTypes)
    }
    
    public nonisolated func roomStateEvents(roomID: String, eventType: String) -> AsyncStream<[MatrixRTCRoomStateEvent]> {
        AsyncStream { continuation in
            let task = Task {
                guard let bridge = await liveBridge(roomID) else {
                    logger?.log(.error, "no bridge for \(roomID), the state feed stays empty")
                    continuation.finish()
                    return
                }
                for await events in bridge.stateEvents(eventType: eventType) {
                    continuation.yield(events)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    /// Re-read on every room info update rather than subscribed directly: the SDK exposes members as
    /// a snapshot iterator, and room info is what changes when someone joins or leaves.
    public nonisolated func joinedMemberIDs(roomID: String) -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                guard let room = try? self.room(roomID) else {
                    continuation.finish()
                    return
                }
                
                let updates = AsyncStream<Void> { infoContinuation in
                    let handle = room.subscribeToRoomInfoUpdates(listener: RoomInfoRelay { infoContinuation.yield(()) })
                    infoContinuation.onTermination = { _ in handle.cancel() }
                }
                
                // Room info fires on any state change in the room, most of which leave membership
                // alone, so the list is only forwarded when it actually differs.
                var lastEmitted: [String]?
                func emitIfChanged() async {
                    guard let members = await Self.joinedMembers(of: room)?.sorted(),
                          Self.shouldEmit(members, lastEmitted: lastEmitted) else { return }
                    lastEmitted = members
                    continuation.yield(members)
                }
                
                await emitIfChanged()
                for await _ in updates {
                    await emitIfChanged()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    /// Whether a freshly read membership is worth forwarding.
    ///
    /// Compared as a sorted list so the question is membership rather than whatever order the store
    /// happened to return. Deliberately **not** compared by count: one person leaving as another
    /// joins keeps the count identical while the membership differs, and the core would carry on
    /// encrypting media for whoever left.
    ///
    /// An empty list is never forwarded, per the port's contract.
    nonisolated static func shouldEmit(_ members: [String], lastEmitted: [String]?) -> Bool {
        !members.isEmpty && members != lastEmitted
    }
    
    /// A store read rather than a network call, but not a cached value either: three store queries
    /// and a deserialise per member. Cheap enough to do per update, which is why this is not
    /// throttled, but worth measuring if a very large room ever misbehaves.
    private static func joinedMembers(of room: Room) async -> [String]? {
        guard let iterator = try? await room.membersNoSync() else { return nil }
        var joined = [String]()
        while let chunk = iterator.nextChunk(chunkSize: 100) {
            joined.append(contentsOf: chunk.filter { $0.membership == .join }.map(\.userId))
        }
        return joined
    }
    
    public nonisolated func isRoomEncrypted(roomID: String) async -> Bool {
        await Task { @MainActor in
            guard let room = try? self.room(roomID) else { return false }
            return await room.isEncrypted()
        }.value
    }
    
    // MARK: - Private
    
    private nonisolated func onMain<T: Sendable>(_ body: @escaping @MainActor (ElementCallSDKTransport) async throws -> T) async throws -> T {
        try await Task { @MainActor in try await body(self) }.value
    }
    
    private nonisolated func liveBridge(_ roomID: String) async -> (any MatrixRTCRoomBridgeProtocol)? {
        await Task { @MainActor in liveBridges[roomID]?.bridge }.value
    }
    
    private nonisolated func bridge(_ roomID: String) async throws -> any MatrixRTCRoomBridgeProtocol {
        guard let bridge = await liveBridge(roomID) else {
            throw MatrixRTCTransportError.failed("No live bridge for \(roomID)")
        }
        return bridge
    }
    
    private func room(_ roomID: String) throws -> Room {
        guard let room = try? client.getRoom(roomId: roomID) else {
            throw MatrixRTCTransportError.failed("Not joined to \(roomID)")
        }
        return room
    }
    
    /// Logs and classifies an SDK failure. The message never includes event content.
    private func sdkCall<T>(_ description: String, in roomID: String, _ body: (Room) async throws -> T) async throws -> T {
        do {
            return try await body(room(roomID))
        } catch let error as MatrixRTCTransportError {
            throw error
        } catch {
            logger?.log(.error, "\(description) failed in \(roomID): \(error)")
            throw error.transportError
        }
    }
}

/// Turns the SDK's listener callback into something a stream can await.
@available(iOS 18, *)
private final class RoomInfoRelay: RoomInfoListener {
    private let onUpdate: @Sendable () -> Void
    
    init(onUpdate: @escaping @Sendable () -> Void) {
        self.onUpdate = onUpdate
    }
    
    func call(roomInfo: RoomInfo) {
        onUpdate()
    }
}
