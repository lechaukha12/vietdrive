import Foundation

/// A compact, platform-neutral payload shared with the Apple Watch app.
/// It intentionally contains no camera or map-database implementation details.
struct PlatformDriveState: Codable, Equatable {
    static let schemaVersion = 1

    let version: Int
    let timestamp: Date
    let speedKmh: Int
    let speedLimitKmh: Int?
    let roadName: String
    let isNavigating: Bool
    let maneuverText: String?
    let maneuverDistanceMeters: Int?
    let safetyAlertID: Int?
    let safetyAlertText: String?
    let safetyAlertDistanceMeters: Int?
    let signCode: String?
    let signAssetName: String?

    static let idle = PlatformDriveState(
        version: schemaVersion,
        timestamp: .distantPast,
        speedKmh: 0,
        speedLimitKmh: nil,
        roadName: "Đang chờ iPhone",
        isNavigating: false,
        maneuverText: nil,
        maneuverDistanceMeters: nil,
        safetyAlertID: nil,
        safetyAlertText: nil,
        safetyAlertDistanceMeters: nil,
        signCode: nil,
        signAssetName: nil
    )
}
