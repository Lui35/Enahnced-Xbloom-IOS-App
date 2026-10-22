import Foundation
import Testing
@testable import XBloomCore

@Test func waterTankWarningUsesPayloadInsteadOfCommandName() {
    var warning = WaterTankWarning()
    warning.ingest(command: 40522, value: nil)
    #expect(!warning.needsCheck)
    warning.ingest(command: 40522, value: 0)
    #expect(!warning.needsCheck)
    let date = Date(timeIntervalSince1970: 100)
    warning.ingest(command: 40522, value: 1, at: date)
    #expect(warning.lastLowReportAt == date)
    warning.ingest(command: 40522, value: nil)
    #expect(warning.needsCheck)
    warning.ingest(command: 40522, value: 0)
    #expect(!warning.needsCheck)
}

@Test func unrelatedPacketsCannotClearTankWarning() {
    let date = Date(timeIntervalSince1970: 100)
    var warning = WaterTankWarning(lastLowReportAt: date)
    for command: UInt16 in [20501, 40510, 40502, 8023] {
        warning.ingest(command: command, value: 0, waterLevelOK: true)
        #expect(warning.lastLowReportAt == date)
    }
}

@Test func machineInfoOnlyClearsTankWarningOnExplicitOK() {
    var warning = WaterTankWarning(lastLowReportAt: Date())
    warning.ingest(command: 40521, value: 0)
    #expect(warning.needsCheck)
    warning.ingest(command: 40521, value: 0, waterLevelOK: false)
    #expect(warning.needsCheck)
    warning.ingest(command: 40521, value: 0, waterLevelOK: true)
    #expect(!warning.needsCheck)
    warning.ingest(command: 40521, value: 0, waterLevelOK: false)
    #expect(!warning.needsCheck)
}
