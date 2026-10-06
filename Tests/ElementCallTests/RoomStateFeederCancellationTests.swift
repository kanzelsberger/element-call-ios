import ElementCallHost
@testable import ElementCallKit
import Foundation
import MatrixRtc
import Testing

@MainActor
struct RoomStateFeederCancellationTests {
    @Test
    func cancellationDoesNotWaitForAJoinedMemberSnapshot() async {
        let feeder = RoomStateFeeder(manager: RtcSessionManagerHandle(),
                                     transport: ElementCallFakeTransport(),
                                     roomID: "!room:example.org",
                                     slotID: MatrixRTCConstants.roomCallSlotID,
                                     compat: .stateEvents,
                                     onMemberCount: { _ in })
        let task = Task { try await feeder.awaitRoomMembers() }
        await Task.yield()
        task.cancel()
        switch await task.result {
        case .success: Issue.record("Cancellation must stop joining before publishing membership")
        case .failure(let error): #expect(error is CancellationError)
        }
    }
    
    @Test
    func stoppingBeforeWaitingAlsoCancelsTheWait() async {
        let feeder = RoomStateFeeder(manager: RtcSessionManagerHandle(),
                                     transport: ElementCallFakeTransport(),
                                     roomID: "!room:example.org",
                                     slotID: MatrixRTCConstants.roomCallSlotID,
                                     compat: .stateEvents,
                                     onMemberCount: { _ in })
        feeder.stop()
        await #expect(throws: CancellationError.self) { try await feeder.awaitRoomMembers() }
    }
}
