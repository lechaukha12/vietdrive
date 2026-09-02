#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

struct VietDriveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let speedKmh: Int
        let speedLimitKmh: Int?
        let roadName: String
        let isNavigating: Bool
        let instruction: String?
        let instructionDistanceMeters: Int?
        let alertText: String?
        let alertDistanceMeters: Int?
        let alertSymbolName: String?
        let isOverSpeed: Bool
        let updatedAt: Date
    }

    let sessionID: String
    let startedAt: Date
}
#endif
