//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallMatrix
import Testing

/// The joined-membership feed decides who receives media keys, so forwarding too little is worse
/// than forwarding too often.
@available(iOS 18, *)
@Suite("Joined membership forwarding")
nonisolated struct JoinedMembershipTests {
    private let alice = "@alice:example.com"
    private let bob = "@bob:example.com"
    private let carol = "@carol:example.com"
    
    @Test("The first read is always forwarded")
    func firstRead() {
        #expect(ElementCallSDKTransport.shouldEmit([alice, bob], lastEmitted: nil))
    }
    
    @Test("An unchanged membership is not forwarded again")
    func unchanged() {
        #expect(!ElementCallSDKTransport.shouldEmit([alice, bob], lastEmitted: [alice, bob]))
    }
    
    /// The reason this is compared by membership and not by count. Bob leaves as Carol arrives, so
    /// the count never moves; gate on it and the core keeps encrypting for Bob.
    @Test("A swap that leaves the count alone is still forwarded")
    func swapAtEqualCount() {
        #expect(ElementCallSDKTransport.shouldEmit([alice, carol], lastEmitted: [alice, bob]))
    }
    
    @Test("Joins and leaves are forwarded")
    func joinsAndLeaves() {
        #expect(ElementCallSDKTransport.shouldEmit([alice, bob, carol], lastEmitted: [alice, bob]))
        #expect(ElementCallSDKTransport.shouldEmit([alice], lastEmitted: [alice, bob]))
    }
    
    /// The port promises never to emit an empty list, so a room that momentarily reads as empty
    /// must not be reported as one.
    @Test("An empty membership is never forwarded")
    func neverEmpty() {
        #expect(!ElementCallSDKTransport.shouldEmit([], lastEmitted: nil))
        #expect(!ElementCallSDKTransport.shouldEmit([], lastEmitted: [alice]))
    }
}
