import AudioToolbox
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Audible and haptic confirmation that the machine came within reach.
///
/// The official app announces a pairing the moment it happens, which matters
/// because connecting is otherwise silent — you are left watching a label to
/// find out whether the machine answered.
@MainActor
enum MachineFeedback {
    private static let soundEnabledKey = "xbloom.connectionSoundEnabled"

    static var isSoundEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: soundEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: soundEnabledKey)
        }
    }

    /// Played once when a connection completes.
    static func machineConnected() {
        guard isSoundEnabled else { return }
        // 1057 is the short ascending "connected" tone iOS uses for devices.
        AudioServicesPlaySystemSound(1057)
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    /// Played when a connection the user was relying on drops away.
    static func machineDisconnected() {
        guard isSoundEnabled else { return }
        AudioServicesPlaySystemSound(1058)
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    /// A short confirmation for an action the machine acknowledged, such as a
    /// tare. Silent by design — the haptic is enough for something the user
    /// just tapped.
    static func acknowledged() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// Preview the tone from Settings, ignoring the enabled switch so the user
    /// can hear what they are turning on.
    static func previewConnectionSound() {
        AudioServicesPlaySystemSound(1057)
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
