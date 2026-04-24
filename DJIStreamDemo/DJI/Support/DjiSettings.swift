import Foundation

enum SettingsDjiDeviceImageStabilization: String, CaseIterable {
    case off
    case rockSteady
    case rockSteadyPlus
    case horizonBalancing
    case horizonSteady
}

enum SettingsDjiDeviceResolution: String, CaseIterable {
    case r1080p = "1080p"
    case r720p = "720p"
    case r480p = "480p"
}

enum SettingsDjiDeviceModel: String {
    case osmoAction2
    case osmoAction3
    case osmoAction4
    case osmoAction5Pro
    case osmoAction6
    case osmoPocket3
    case osmo360
    case unknown

    func hasNewProtocol() -> Bool {
        switch self {
        case .osmoAction5Pro, .osmoAction6, .osmo360:
            return true
        default:
            return false
        }
    }
}
