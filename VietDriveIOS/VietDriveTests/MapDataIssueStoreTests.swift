import XCTest
@testable import VietDrive

final class MapDataIssueStoreTests: XCTestCase {
    func testIncorrectAlertReportPersistsAsPending() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let store = MapDataIssueStore(fileURL: fileURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        let alert = DriveAlert(
            id: 42,
            kind: .roadSign,
            speedLimit: 0,
            latitude: 10.77,
            longitude: 106.70,
            message: "Biển thử nghiệm",
            province: "",
            distanceMeters: 100,
            signCode: "P101",
            source: "OpenStreetMap",
            confidence: 0.8
        )

        store.submit(alert: alert, reason: "Sai chiều đường")
        let report = try XCTUnwrap(store.reports().first)

        XCTAssertEqual(report.alertID, 42)
        XCTAssertEqual(report.reason, "Sai chiều đường")
        XCTAssertEqual(report.status, "pending")
    }
}
