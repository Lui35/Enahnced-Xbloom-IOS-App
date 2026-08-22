import Foundation

/// The transport-independent program used to load and start one recipe.
///
/// Packet construction belongs to `XBloomProtocol`; ordering, settling time,
/// and launch safety belong here. Keeping both out of the SwiftUI page and the
/// CoreBluetooth delegate makes the physical workflow replayable in tests.
public struct BrewCommandPlan: Equatable, Sendable {
    public enum StepKind: Equatable, Sendable {
        case configureDose
        case configureCup
        case uploadRecipe
        case execute
    }

    public struct Step: Equatable, Sendable {
        public let kind: StepKind
        public let packet: Data
        public let settleAfter: TimeInterval

        public init(kind: StepKind, packet: Data, settleAfter: TimeInterval) {
            self.kind = kind
            self.packet = packet
            self.settleAfter = settleAfter
        }
    }

    public let steps: [Step]

    public init(recipe: Recipe) throws {
        let packets = try XBloomProtocol.brewSequence(for: recipe)
        guard packets.count == 4 else { throw XBloomProtocolError.malformedPacket }
        steps = [
            Step(kind: .configureDose, packet: packets[0], settleAfter: 1),
            Step(kind: .configureCup, packet: packets[1], settleAfter: 1),
            Step(kind: .uploadRecipe, packet: packets[2], settleAfter: 1),
            Step(kind: .execute, packet: packets[3], settleAfter: 0),
        ]
    }
}

public enum BrewInterlockDecision: Equatable, Sendable {
    case observing
    case grindingConfirmed
    case pourAllowed
    case stopUnexpectedPour
}

/// Prevents a grinder-enabled program from silently pouring over whole beans.
///
/// A display page is deliberately not enough to stop machinery. The previous
/// implementation stopped on page 35 and cancelled valid starts. This guard
/// waits for the machine's actual `wateringPhase`; it only stops at that point
/// when no grinder event or grinding page has appeared first.
public struct BrewGrinderInterlock: Equatable, Sendable {
    public let requiresGrinding: Bool
    public private(set) var observedGrinding = false
    public private(set) var reachedFirstPour = false

    public init(requiresGrinding: Bool) {
        self.requiresGrinding = requiresGrinding
    }

    public mutating func ingest(command: UInt16, value: UInt32?) -> BrewInterlockDecision {
        guard requiresGrinding, !reachedFirstPour else { return .observing }
        guard let notification = XBloomNotification(rawValue: command) else { return .observing }

        switch notification {
        case .deviceBeginGrinder, .grinderDoing, .grindBegin, .deviceGears,
             .deviceGrinderFinish:
            guard !observedGrinding else { return .observing }
            observedGrinding = true
            return .grindingConfirmed

        case .deviceCurrentPage where value == 34:
            guard !observedGrinding else { return .observing }
            observedGrinding = true
            return .grindingConfirmed

        case .wateringPhase:
            reachedFirstPour = true
            return observedGrinding ? .pourAllowed : .stopUnexpectedPour

        default:
            return .observing
        }
    }
}
