import HealthKit

enum SleepStageMapper {

    /// Google Fit com.google.sleep.segment intVal reference:
    /// 1 = Awake (during sleep cycle)
    /// 2 = Sleep (generic/non-granular)
    /// 3 = Out-of-bed
    /// 4 = Light sleep
    /// 5 = Deep sleep
    /// 6 = REM sleep
    ///
    /// Returns nil for "out of bed" (3) — there's no clean Apple equivalent for a
    /// mid-session out-of-bed marker, so those points are skipped rather than guessed at.
    static func map(_ intVal: Int) -> HKCategoryValueSleepAnalysis? {
        switch intVal {
        case 1: return .awake
        case 2: return .asleepUnspecified
        case 4: return .asleepCore
        case 5: return .asleepDeep
        case 6: return .asleepREM
        default: return nil
        }
    }

    /// Human-readable name for an Apple HealthKit sleep category — debugging/display only.
    static func sleepStageName(_ stage: HKCategoryValueSleepAnalysis) -> String {
        switch stage {
        case .inBed: return "In Bed"
        case .awake: return "Awake"
        case .asleepUnspecified: return "Asleep (Unspecified)"
        case .asleepCore: return "Asleep (Core/Light)"
        case .asleepDeep: return "Asleep (Deep)"
        case .asleepREM: return "Asleep (REM)"
        @unknown default: return "Unknown (\(stage.rawValue))"
        }
    }

    /// Human-readable name for a raw Google Fit intVal — debugging/display only.
    static func sleepSourceName(_ intVal: Int) -> String {
        switch intVal {
        case 1: return "Awake"
        case 2: return "Sleep (generic)"
        case 3: return "Out-of-bed"
        case 4: return "Light"
        case 5: return "Deep"
        case 6: return "REM"
        default: return "Unknown (\(intVal))"
        }
    }
}
