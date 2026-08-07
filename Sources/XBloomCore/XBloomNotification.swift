import Foundation

/// The machine's command and notification identifiers, using the vendor's own
/// names as recovered from the official app's `BLECommands` enum.
///
/// The enum mixes both directions — the machine echoes most app commands back
/// as acknowledgements — so a single table covers everything that can appear in
/// a traffic recording. Anything not listed here is genuinely unknown and is
/// surfaced as such rather than quietly ignored.
public enum XBloomNotification: UInt16, Sendable, CaseIterable {
    case spindleMoveLeft = 2500
    case spindleMoveRight = 2501
    case grindAdjust = 3500
    case grindZero = 3502
    case grindBegin = 3503
    case grindEnd = 3505
    case brewerStopRotation = 4503
    case brewerCircular = 4504
    case brewerSpiral = 4505
    case brewerBeginDirect = 4506
    case brewerStopDirect = 4507
    case brewerWaterSource = 4508
    case brewerTemperatureDirect = 4510
    case teaRecipeMarking = 4512
    case teaRecipeSend = 4513
    case recipeSend = 8001
    case recipeMarking = 8002
    case inScalePage = 8003
    case recipeSendNoGrinder = 8004
    case weightSwitchUnit = 8005
    case inGrinderPage = 8006
    case inBrewerPage = 8007
    case deviceNoSleep = 8008
    case deviceIntoSleep = 8009
    case deviceTemperature = 8010
    case deviceWakeupSleep = 8011
    case outGrinderPage = 8012
    case outBrewerPage = 8013
    case outScalePage = 8014
    case deviceUnitChange = 8015
    case brewerPourMode = 8016
    case recipeMarkingCancel = 8017
    case grindPause = 8018
    case brewerPauseDirect = 8019
    case grindRestart = 8020
    case brewerRestart = 8021
    case deviceBackToHome = 8022
    case deviceCurrentPage = 8023
    case deviceMTUNegotiate = 8100
    case deviceOTAUpdate = 8101
    case recipeBypass = 8102
    case deviceLightBrightness = 8103
    case devicePodType = 8104
    case deviceGrinderSize = 8105
    case deviceGrinderSpeed = 8106
    case deviceBrewerMode = 8107
    case deviceBrewerTemperature = 8108
    case deviceEasyModeBegin = 8111
    case teaChangeWaitTime = 8113
    case weightCleared = 8500
    case deviceInGrinder = 9000
    case deviceInBrewer = 9001
    case deviceInScale = 9002
    case deviceBeginGrinder = 9003
    case deviceOutGrinder = 9004
    case deviceBeginBrewer = 9005
    case deviceOutBrewer = 9006
    case deviceOutScale = 9008
    case deviceGrinderPass = 9009
    case deviceBrewerPass = 9010
    case deviceTeaUnpass = 9011
    case deviceTeaWait = 9012
    case weightCurrent = 10507
    case deviceReadPourRadius = 11506
    case deviceWritePourRadius = 11507
    case deviceReadShakePPS = 11508
    case deviceWriteShakePPS = 11509
    case easyModeRecipeSend = 11510
    case easyModeType = 11511
    case easyModeRecipeOrder = 11512
    case deviceEasyModeChange = 11518
    case weightRealTime = 20501
    case tagNFCXID = 40501
    case brewerStart = 40502
    case spindleMovingLeft = 40503
    case spindleMovingLeftStop = 40504
    case deviceGears = 40505
    case grinderDoing = 40506
    case deviceGrinderFinish = 40507
    case spindleMovingRight = 40508
    case spindleMovingRightStop = 40509
    /// Emitted at the start of every pour. Its four-byte payload is the
    /// zero-based index of the pour that is beginning — verified against a
    /// recorded three-pour brew, which reported 0 and then 1.
    case wateringPhase = 40510
    case deviceWateringFinish = 40511
    case takeCup = 40512
    case brewerFinish = 40513
    case deviceSleep = 40514
    case brewerStartStop = 40515
    case brewerStopStart = 40516
    case grinderEmptyAbnormal = 40517
    case brewFlowPause = 40518
    case brewFlowStop = 40519
    case bypassBegin = 40520
    case deviceSyncInfo = 40521
    case waterTankVolumeLow = 40522
    /// Poured volume for the running recipe, as a float32 in **microliters**.
    case brewerVolume = 40523
    case brewFlowResume = 40524
    case easyModeRecipeNum = 40525
    case gearResetZero = 40526
    case pourFirstVibrationBefore = 40527
    case gearStartResetZero = 50038
    case gearResettingZero = 50039

    /// Continuous measurement channels rather than lifecycle events. They
    /// arrive several times a second and say nothing about what stage the
    /// machine has reached.
    public var isMeasurement: Bool {
        switch self {
        case .brewerVolume, .weightRealTime, .weightCurrent,
             .deviceBrewerTemperature, .deviceSyncInfo, .deviceGears:
            true
        default:
            false
        }
    }
}
