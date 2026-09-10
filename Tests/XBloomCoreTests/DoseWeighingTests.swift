import Foundation
import Testing
@testable import XBloomCore

@Test func doseReadoutFollowsZeroInsteadOfHoldingThePreviousBeans() {
    var state = DoseWeighingState()
    state.ingest(weight: 18)
    #expect(state.measured == 18)
    state.ingest(weight: 0)
    #expect(state.measured == 0)
    #expect(!state.isBrewable)
    state.ingest(weight: -40)
    #expect(state.measured == 0)
}

@Test func replacingBeansWithServerDoesNotChangeConfirmedDose() {
    var state = DoseWeighingState()
    state.ingest(weight: 18.3)
    let confirmed = state.confirm()
    #expect(confirmed)
    for reading in [-40.0, 0, 280, 0] {
        state.ingest(weight: reading)
        #expect(state.confirmedDose == 18.3)
    }
    state.tare()
    #expect(state.confirmedDose == 18.3)
    state.reweigh()
    #expect(state.confirmedDose == nil)
    let reconfirmed = state.confirm()
    #expect(!reconfirmed)
}

@Test func tareNotificationClearsLiveWeightAndManualAdjustment() throws {
    let packet = XBloomProtocol.command(.weightCleared)
    let update = try XBloomProtocol.parseNotification(packet)
    #expect(update.weight == 0)
    var state = DoseWeighingState()
    state.ingest(weight: 16)
    state.adjustment = 18
    state.tare()
    #expect(state.measured == 0)
    #expect(state.adjustment == nil)
}
