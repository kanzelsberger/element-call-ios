//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import Foundation

// Temporary: the widget-driver stopgap. The released SDK bindings lack delayed events, a room-state
// feed and to-device messaging, but their widget driver implements all of them for Element Call web.
// This speaks the widget API to that driver in-process, with no web view.
//
// Delete this folder once the bindings gain all of:
//
//   - `Room.sendDelayedEvent` / `sendDelayedStateEvent` returning the delay ID, and
//     `updateDelayedEvent(cancel|restart)`.
//   - A room-state feed delivering the full list of a type per change, with event ID, sender, state
//     key, timestamp and content.
//   - `Client.sendToDeviceMessage` returning per-recipient failures.
//   - `Client.subscribeToToDeviceMessages` delivering encryption info: attested sender, sender
//     device ID and cross-signing status. The widget path gives only type, content, sender and
//     whether it was encrypted, which is why the trust note on `toDeviceMessage(from:)` exists.
//   - `Room.sendStickyRaw` (MSC4354), without which only the state-event compatibility mode works.
//
// Then give `ElementCallSDKTransport` direct SDK calls in place of its per-room bridge. Its
// `openBridge` is the only place a bridge is created, so that is the only seam to unpick.

/// One widget driver for one room, as the RTC core's Matrix bridge.
///
/// Wire protocol (verified against the SDK's widget machine): every message is
/// `{api, widgetId, requestId, action, data}`; a response echoes the request with a `response` key.
/// With `initAfterContentLoad` off the driver opens with a `capabilities` request, calls the
/// capabilities provider, confirms with `notify_capabilities`, then pushes the current room state.
/// Requests sent before that are silently dropped, and the driver keeps at most 15 unanswered
/// requests of its own, so everything it sends is answered inline.
///
/// State arrives as deltas (`update_state` from sync, `send_event` for timeline-borne state) while the
/// core wants the full state on every tick. Room state is replace-only, a leave being a present `{}`
/// event, so the latest event per state key *is* the full state and the map below re-emits it whole.
@available(iOS 18, *)
actor WidgetMatrixBridge: MatrixRTCRoomBridgeProtocol {
    nonisolated let roomID: String
    
    private enum Phase: Equatable {
        case idle, negotiating, ready, stopped
    }
    
    private struct PendingRequest {
        let continuation: CheckedContinuation<Result<Data, MatrixRTCRoomBridgeError>, Never>
        let timeout: Task<Void, Never>
    }
    
    private let widgetID: String
    private let runDriver: @Sendable () async -> Void
    private let requestTimeout: Duration
    
    /// How long the driver handshake may take, kept separate from `requestTimeout` even though it
    /// defaults to it. A test that wants to observe a request timing out has to make
    /// `requestTimeout` very short, and while these were one value that also shortened negotiation:
    /// the handshake is two round-trips, so 50 ms was enough to fail it under load. Negotiation then
    /// tore the bridge down and the next reply never came, so a test waiting on it hung until its
    /// suite time limit -- a minute, blamed on whichever test held it. Two knobs, no race.
    private let negotiationTimeoutDuration: Duration
    
    private var channel: (any WidgetDriverChannel)?
    private var phase: Phase = .idle
    private var negotiationWaiters = [CheckedContinuation<Result<Void, MatrixRTCRoomBridgeError>, Never>]()
    private var negotiationTimeout: Task<Void, Never>?
    private var pending = [String: PendingRequest]()
    
    /// Event type → state key → latest event: the current state of every type we receive.
    private var state = [String: [String: MatrixRTCRoomStateEvent]]()
    private var stateSubscribers = [UUID: (eventType: String, continuation: AsyncStream<[MatrixRTCRoomStateEvent]>.Continuation)]()
    private var toDeviceSubscribers = [UUID: AsyncStream<MatrixRTCToDeviceMessage>.Continuation]()
    private let logger: (any ElementCallLoggingProtocol)?
    
    /// - Parameters:
    ///   - channel: the driver's handle (or a fake in tests).
    ///   - runDriver: runs the driver; must not capture the handle, or the driver never stops.
    init(roomID: String,
         widgetID: String,
         channel: any WidgetDriverChannel,
         requestTimeout: Duration = .seconds(30),
         negotiationTimeout: Duration? = nil,
         logger: (any ElementCallLoggingProtocol)? = nil,
         runDriver: @escaping @Sendable () async -> Void) {
        self.roomID = roomID
        self.widgetID = widgetID
        self.channel = channel
        self.requestTimeout = requestTimeout
        negotiationTimeoutDuration = negotiationTimeout ?? requestTimeout
        self.logger = logger
        self.runDriver = runDriver
    }
    
    /// Forwards the caller's position rather than its own, or every line in this file would be
    /// attributed to the line below.
    private func log(_ level: ElementCallLogLevel, _ message: String, file: String = #fileID, line: Int = #line) {
        logger?.log(level, "WidgetBridge: " + message, file: file, line: line)
    }
    
    // MARK: - Lifecycle
    
    func start() async -> Result<Void, MatrixRTCRoomBridgeError> {
        guard phase == .idle, let channel else { return .failure(.notRunning) }
        phase = .negotiating
        log(.info, "starting for \(roomID)")
        
        let runDriver = runDriver
        Task.detached { await runDriver() }
        
        // Receiving must be under way before negotiation is awaited: the driver's first request
        // times out after 10 s.
        Task { [weak self] in
            while let raw = await channel.recv() {
                guard let self, await self.handleIncoming(raw) else { return }
            }
            await self?.driverStopped()
        }
        
        negotiationTimeout = Task { [weak self, negotiationTimeoutDuration] in
            try? await Task.sleep(for: negotiationTimeoutDuration)
            await self?.failNegotiation(with: .timedOut)
        }
        return await withCheckedContinuation { continuation in
            negotiationWaiters.append(continuation)
        }
    }
    
    func stop() async {
        guard phase != .stopped, let channel else { return }
        log(.info, "stopping for \(roomID)")
        tearDown()
        // The driver only stops once its handle is gone, and the pending `recv()` holds the handle:
        // a request the machine always answers makes that `recv()` return, after which nothing
        // receives again and the handle is released.
        _ = await channel.send(msg: Self.serialize(["api": "fromWidget",
                                                    "widgetId": widgetID,
                                                    "requestId": UUID().uuidString,
                                                    "action": "supported_api_versions",
                                                    "data": [String: Any]()]) ?? "")
    }
    
    // MARK: - Sends
    
    func sendDelayedEvent(eventType: String, stateKey: String?, contentJSON: String, delayMs: UInt64) async -> Result<String, MatrixRTCRoomBridgeError> {
        guard let content = Self.parseObject(contentJSON) else { return .failure(.invalidResponse("content is not a JSON object")) }
        var data: [String: Any] = ["type": eventType, "content": content, "delay": delayMs]
        if let stateKey {
            data["state_key"] = stateKey
        }
        return await request(action: "send_event", data: data).flatMap { response in
            guard let delayID = response["delay_id"] as? String else {
                return .failure(.invalidResponse("no delay_id in the send_event response"))
            }
            return .success(delayID)
        }
    }
    
    func updateDelayedEvent(delayID: String, action: MatrixRTCDelayedEventAction) async -> Result<Void, MatrixRTCRoomBridgeError> {
        let wireAction = switch action {
        case .cancel: "cancel"
        case .restart: "restart"
        }
        return await request(action: "org.matrix.msc4157.update_delayed_event", data: ["delay_id": delayID, "action": wireAction]).map { _ in }
    }
    
    func sendRoomEvent(eventType: String, contentJSON: String) async -> Result<String, MatrixRTCRoomBridgeError> {
        guard let content = Self.parseObject(contentJSON) else { return .failure(.invalidResponse("content is not a JSON object")) }
        return await request(action: "send_event", data: ["type": eventType, "content": content]).flatMap { response in
            guard let eventID = response["event_id"] as? String else {
                return .failure(.invalidResponse("no event_id in the send_event response"))
            }
            return .success(eventID)
        }
    }
    
    /// MSC4515. The driver forwards this to `Client::discover_rtc_transports`, which reads the
    /// discovery endpoint and falls back to the well-known `rtc_foci`, with caching, so none of that
    /// has to be reimplemented here.
    func rtcTransports() async -> Result<[MatrixRTCTransport], MatrixRTCRoomBridgeError> {
        await request(action: "org.matrix.msc4515.get_rtc_transports", data: [:]).flatMap { response in
            guard let transports = response["rtc_transports"] as? [[String: Any]] else {
                return .failure(.invalidResponse("no rtc_transports in the get_rtc_transports response"))
            }
            return .success(Self.parseTransports(transports))
        }
    }
    
    /// Both the discovery endpoint and the well-known describe a transport the same way, so this is
    /// the shape either source produces.
    static func parseTransports(_ transports: [[String: Any]]) -> [MatrixRTCTransport] {
        transports.compactMap { transport in
            guard let type = transport["type"] as? String else { return nil }
            if type == "livekit" {
                guard let urlString = transport["livekit_service_url"] as? String,
                      let url = URL(string: urlString) else { return nil }
                return .liveKit(serviceURL: url)
            }
            // Kept rather than dropped: the core logs what it cannot use, which is the difference
            // between a homeserver offering nothing and offering something we do not speak.
            return .unsupported(type: type)
        }
    }
    
    func sendToDeviceMessage(eventType: String, messages: [String: [String: String]]) async -> Result<[String: [String]], MatrixRTCRoomBridgeError> {
        var wireMessages = [String: [String: Any]]()
        for (userID, devices) in messages {
            for (deviceID, contentJSON) in devices {
                guard let content = Self.parseObject(contentJSON) else { return .failure(.invalidResponse("content is not a JSON object")) }
                wireMessages[userID, default: [:]][deviceID] = content
            }
        }
        return await request(action: "send_to_device", data: ["type": eventType, "messages": wireMessages]).map { response in
            response["failures"] as? [String: [String]] ?? [:]
        }
    }
    
    // MARK: - Feeds
    
    nonisolated func stateEvents(eventType: String) -> AsyncStream<[MatrixRTCRoomStateEvent]> {
        let (stream, continuation) = AsyncStream<[MatrixRTCRoomStateEvent]>.makeStream()
        let id = UUID()
        Task { await self.addStateSubscriber(id: id, eventType: eventType, continuation: continuation) }
        continuation.onTermination = { _ in
            Task { await self.removeStateSubscriber(id: id) }
        }
        return stream
    }
    
    nonisolated func toDeviceMessages() -> AsyncStream<MatrixRTCToDeviceMessage> {
        let (stream, continuation) = AsyncStream<MatrixRTCToDeviceMessage>.makeStream()
        let id = UUID()
        Task { await self.addToDeviceSubscriber(id: id, continuation: continuation) }
        continuation.onTermination = { _ in
            Task { await self.removeToDeviceSubscriber(id: id) }
        }
        return stream
    }
    
    private func addStateSubscriber(id: UUID, eventType: String, continuation: AsyncStream<[MatrixRTCRoomStateEvent]>.Continuation) {
        guard phase != .stopped else {
            continuation.finish()
            return
        }
        stateSubscribers[id] = (eventType, continuation)
        if let current = state[eventType], !current.isEmpty {
            continuation.yield(Array(current.values))
        }
    }
    
    private func removeStateSubscriber(id: UUID) {
        stateSubscribers[id] = nil
    }
    
    private func addToDeviceSubscriber(id: UUID, continuation: AsyncStream<MatrixRTCToDeviceMessage>.Continuation) {
        guard phase != .stopped else {
            continuation.finish()
            return
        }
        toDeviceSubscribers[id] = continuation
    }
    
    private func removeToDeviceSubscriber(id: UUID) {
        toDeviceSubscribers[id] = nil
    }
    
    // MARK: - Requests
    
    private func request(action: String, data: [String: Any]) async -> Result<[String: Any], MatrixRTCRoomBridgeError> {
        guard phase == .ready, let channel else { return .failure(.notRunning) }
        let requestID = UUID().uuidString
        guard let message = Self.serialize(["api": "fromWidget",
                                            "widgetId": widgetID,
                                            "requestId": requestID,
                                            "action": action,
                                            "data": data]) else {
            return .failure(.invalidResponse("cannot encode the \(action) request"))
        }
        log(.debug, "→ \(action) \(requestID)")
        
        let reply: Result<Data, MatrixRTCRoomBridgeError> = await withCheckedContinuation { continuation in
            let timeout = Task { [weak self, requestTimeout] in
                try? await Task.sleep(for: requestTimeout)
                await self?.resume(requestID, with: .failure(.timedOut))
            }
            pending[requestID] = PendingRequest(continuation: continuation, timeout: timeout)
            Task {
                if await !channel.send(msg: message) {
                    resume(requestID, with: .failure(.notRunning))
                }
            }
        }
        return reply.flatMap { data in
            guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.invalidResponse("the \(action) response is not a JSON object"))
            }
            return .success(response)
        }
    }
    
    private func resume(_ requestID: String, with result: Result<Data, MatrixRTCRoomBridgeError>) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.timeout.cancel()
        request.continuation.resume(returning: result)
    }
    
    // MARK: - Incoming
    
    /// - Returns: whether to keep receiving.
    private func handleIncoming(_ raw: String) async -> Bool {
        guard phase != .stopped else { return false }
        guard let message = Self.parseObject(raw), message["widgetId"] as? String == widgetID else {
            log(.warning, "ignoring a message for another widget")
            return true
        }
        let api = message["api"] as? String
        let action = message["action"] as? String ?? ""
        let requestID = message["requestId"] as? String ?? ""
        
        if api == "fromWidget", let response = message["response"] {
            handleResponse(response, action: action, requestID: requestID)
            return true
        }
        guard api == "toWidget" else { return true }
        
        log(.debug, "← \(action) \(requestID)")
        let data = message["data"] as? [String: Any] ?? [:]
        var response: [String: Any] = [:]
        switch action {
        case "capabilities":
            response["capabilities"] = WidgetCapabilityGrant.capabilityStrings
        case "notify_capabilities":
            didNegotiate(approved: data["approved"] as? [String] ?? [])
        case "update_state":
            var changedTypes = Set<String>()
            for case let event as [String: Any] in data["state"] as? [Any] ?? [] {
                if let eventType = upsert(event) {
                    changedTypes.insert(eventType)
                }
            }
            changedTypes.forEach(emitSnapshot)
        case "send_event":
            if data["state_key"] != nil, let eventType = upsert(data) {
                emitSnapshot(of: eventType)
            }
        case "send_to_device":
            deliverToDevice(data)
        default:
            break
        }
        
        var echo = message
        echo["response"] = response
        if let channel, let encoded = Self.serialize(echo) {
            if await !channel.send(msg: encoded) {
                driverStopped()
                return false
            }
        }
        return phase != .stopped
    }
    
    private func handleResponse(_ response: Any, action: String, requestID: String) {
        guard pending[requestID] != nil else {
            // Our own stop poke, or a request that already timed out.
            log(.debug, "unmatched response to \(action) \(requestID)")
            return
        }
        guard let object = response as? [String: Any] else {
            resume(requestID, with: .failure(.invalidResponse("the \(action) response is not a JSON object")))
            return
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown error"
            let matrixError = error["matrix_api_error"] as? [String: Any]
            let body = matrixError?["response"] as? [String: Any]
            log(.warning, "\(action) \(requestID) failed: \(message)")
            resume(requestID, with: .failure(.matrixAPI(errcode: body?["errcode"] as? String,
                                                        httpStatus: matrixError?["http_status"] as? Int,
                                                        message: message)))
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            resume(requestID, with: .failure(.invalidResponse("cannot encode the \(action) response")))
            return
        }
        resume(requestID, with: .success(data))
    }
    
    private func didNegotiate(approved: [String]) {
        guard phase == .negotiating else { return }
        log(.info, "negotiated \(approved.count) capabilities for \(roomID)")
        phase = .ready
        negotiationTimeout?.cancel()
        negotiationTimeout = nil
        let waiters = negotiationWaiters
        negotiationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: .success(())) }
    }
    
    private func failNegotiation(with error: MatrixRTCRoomBridgeError) {
        guard phase == .negotiating else { return }
        log(.error, "negotiation failed for \(roomID): \(error)")
        tearDown()
    }
    
    /// A state event arrived (initial read, sync state block or timeline): remember the latest per
    /// state key. One batch yields one snapshot, so emitting is the caller's.
    /// - Returns: the event type when the state changed.
    private func upsert(_ event: [String: Any]) -> String? {
        guard let eventType = event["type"] as? String,
              let stateKey = event["state_key"] as? String,
              let sender = event["sender"] as? String,
              let content = event["content"] as? [String: Any],
              let contentJSON = Self.serialize(content) else {
            log(.warning, "ignoring a malformed state event")
            return nil
        }
        let eventID = event["event_id"] as? String
        if let eventID, state[eventType]?[stateKey]?.eventID == eventID {
            return nil // The same change through both routes.
        }
        let timestamp = (event["origin_server_ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        state[eventType, default: [:]][stateKey] = MatrixRTCRoomStateEvent(eventID: eventID,
                                                                           eventType: eventType,
                                                                           stateKey: stateKey,
                                                                           sender: sender,
                                                                           originServerTimestamp: timestamp,
                                                                           contentJSON: contentJSON)
        return eventType
    }
    
    /// Hands subscribers the whole current state of the type.
    private func emitSnapshot(of eventType: String) {
        let snapshot = Array(state[eventType, default: [:]].values)
        guard !snapshot.isEmpty else { return }
        for (subscribedType, continuation) in stateSubscribers.values where subscribedType == eventType {
            continuation.yield(snapshot)
        }
    }
    
    /// The driver hands over `{type, content, sender, encrypted}` only: it has already dropped
    /// cleartext in an encrypted room and attested the sender of an encrypted message, but reports
    /// neither the sender's device nor whether it is cross-signed. The device is read from the key
    /// message itself and from nowhere else: a key that names none is passed on with none, and the
    /// core drops it, rather than being attributed to whatever device the sender's membership
    /// happens to name. An encrypted message is taken as cross-signed, the trust Element Call web
    /// gets through this same driver (see this folder's header for what retires the stopgap).
    private func deliverToDevice(_ data: [String: Any]) {
        guard let eventType = data["type"] as? String,
              let sender = data["sender"] as? String,
              let content = data["content"] as? [String: Any],
              let contentJSON = Self.serialize(content) else {
            log(.warning, "ignoring a malformed to-device message")
            return
        }
        let wasEncrypted = data["encrypted"] as? Bool ?? false
        let deviceID = Self.claimedDeviceID(in: content)
        if deviceID == nil {
            // Field names only, never values: which shape of key message the peer speaks.
            log(.info, "\(eventType) from \(sender) names no device (fields: \(content.keys.sorted()))")
        }
        let message = MatrixRTCToDeviceMessage(eventType: eventType,
                                               attestedSenderID: sender,
                                               senderDeviceID: deviceID,
                                               isSenderCrossSigned: wasEncrypted,
                                               wasEncrypted: wasEncrypted,
                                               contentJSON: contentJSON)
        toDeviceSubscribers.values.forEach { $0.yield(message) }
    }
    
    /// The device the key message claims to come from: Element Call has written it at the top level
    /// (`device_id`) and, more recently, as `member.claimed_device_id` (matrix-js-sdk's
    /// `EncryptionKeysToDeviceEventContent`). Claimed is the right word: through the driver
    /// the real sender device is not knowable, so this is the trust level embedded Element Call web
    /// has today.
    private nonisolated static func claimedDeviceID(in content: [String: Any]) -> String? {
        if let deviceID = content["device_id"] as? String {
            return deviceID
        }
        let member = content["member"] as? [String: Any]
        return (member?["claimed_device_id"] ?? member?["device_id"]) as? String
    }
    
    private func driverStopped() {
        guard phase != .stopped else { return }
        log(.warning, "driver stopped for \(roomID)")
        tearDown()
    }
    
    /// Fails everything in flight and closes every feed; the channel reference goes with it.
    private func tearDown() {
        phase = .stopped
        negotiationTimeout?.cancel()
        negotiationTimeout = nil
        let waiters = negotiationWaiters
        negotiationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: .failure(.notRunning)) }
        for requestID in Array(pending.keys) {
            resume(requestID, with: .failure(.notRunning))
        }
        stateSubscribers.values.forEach { $0.continuation.finish() }
        stateSubscribers.removeAll()
        toDeviceSubscribers.values.forEach { $0.finish() }
        toDeviceSubscribers.removeAll()
        channel = nil
    }
    
    // MARK: - JSON
    
    private nonisolated static func parseObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    
    /// Sorted keys, deliberately: the machine's request enum is tagged on `action` with `data` as
    /// its content, and `data` arriving first makes serde buffer it, which its raw JSON fields
    /// cannot be read from. Alphabetical order puts `action` before `data` every time.
    private nonisolated static func serialize(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
