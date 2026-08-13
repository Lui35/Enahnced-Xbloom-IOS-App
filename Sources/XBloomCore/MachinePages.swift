import Foundation

/// Which of the machine's own screens the app currently holds open.
///
/// The xBloom hands out one subsystem at a time and only releases it when the
/// app leaves the screen that claimed it — `out_scale_page` and
/// `out_grinder_page` are how the vendor's own app gives the scale and the
/// grinder back.
///
/// That release has to happen *before* a brew's setup commands go out. Sent
/// from a view's `onDisappear` it lands in the middle of the
/// `8102 → 8104 → 8001 → 8002` sequence instead, and a grinding recipe started
/// straight after weighing a dose poured water without ever grinding.
public struct MachinePages: Equatable, Sendable {
    /// The scale screen, opened by `in_scale_page` for weighing and taring.
    public var scale: Bool
    /// The grinder screen, opened by `in_grinder_page` for direct grinder control.
    public var grinder: Bool

    public init(scale: Bool = false, grinder: Bool = false) {
        self.scale = scale
        self.grinder = grinder
    }

    public var isEmpty: Bool { !scale && !grinder }

    /// The page exits that must reach the machine, in order, before a brew's
    /// first setup command. A page the app never opened sends nothing: an
    /// unnecessary exit is one more frame arriving next to the recipe.
    public var exitsBeforeBrew: [XBloomCommand] {
        var exits: [XBloomCommand] = []
        if scale { exits.append(.outScalePage) }
        if grinder { exits.append(.outGrinderPage) }
        return exits
    }
}
