import CoreLocation
import XCTest
@testable import VietDrive

@MainActor
final class CommunityContributionTests: XCTestCase {
    func testValidationAcceptsEvidenceBackedVietnamPoint() {
        let contribution = makeContribution()
        XCTAssertTrue(CommunityImportParser.validate(contribution).isValid)
    }

    func testValidationRejectsOutsideVietnamAndMissingEvidence() {
        let contribution = CommunityContribution(
            kind: .roadSign,
            signCode: "P130",
            warningText: "Cấm dừng và đỗ xe",
            geometry: .point(latitude: 1, longitude: 1),
            submitter: "tester"
        )
        let errors = CommunityImportParser.validate(contribution).errors
        XCTAssertTrue(errors.contains("Tọa độ nằm ngoài Việt Nam"))
        XCTAssertTrue(errors.contains("Cần liên kết nguồn hoặc ghi chú bằng chứng"))
    }

    func testNearbySameKindAndCodeIsDuplicate() {
        let original = makeContribution()
        var duplicate = makeContribution()
        duplicate.sourceReference = "https://example.org/different"
        duplicate.geometry = .point(latitude: 10.77690001, longitude: 106.70090001)
        XCTAssertTrue(CommunityImportParser.isDuplicate(duplicate, in: [original]))
    }

    func testGeoJSONPreviewParsesAndFiltersKnownSource() throws {
        let data = try XCTUnwrap("""
        {
          "type": "FeatureCollection",
          "features": [
            {
              "type": "Feature",
              "geometry": {"type": "Point", "coordinates": [106.7009, 10.7769]},
              "properties": {
                "sign_code": "P130",
                "warning_text": "Cấm dừng và đỗ xe",
                "source_ref": "https://www.openstreetmap.org/node/123"
              }
            }
          ]
        }
        """.data(using: .utf8))
        let preview = try CommunityImportParser.preview(
            data: data,
            fileName: "signs.geojson",
            submitter: "admin",
            existing: [],
            knownSourceReferences: ["https://www.openstreetmap.org/node/123"]
        )
        XCTAssertTrue(preview.candidates.isEmpty)
        XCTAssertEqual(preview.duplicateCount, 1)
        XCTAssertTrue(preview.issues.isEmpty)
    }

    func testCSVPreviewParsesQuotedRuleJSONAndLineGeometry() throws {
        let data = try XCTUnwrap("""
        id,way_id,road_name,highway,parking_rules,geometry_json,osm_url
        1,123,Đường thử nghiệm,residential,"{""parking:both"": ""no""}","[[106.7009,10.7769],[106.7010,10.7770]]",https://www.openstreetmap.org/way/123
        """.data(using: .utf8))
        let preview = try CommunityImportParser.preview(
            data: data,
            fileName: "parking.csv",
            submitter: "admin",
            existing: []
        )
        XCTAssertEqual(preview.candidates.count, 1)
        XCTAssertEqual(preview.candidates.first?.kind, .parkingRestriction)
        XCTAssertEqual(preview.candidates.first?.geometry.type, .lineString)
        XCTAssertTrue(preview.issues.isEmpty)
    }

    func testMalformedGeometryAppearsAsIssueInsteadOfDisappearing() throws {
        let data = try XCTUnwrap("""
        {"type":"FeatureCollection","features":[
          {"type":"Feature","geometry":null,"properties":{"warning_text":"Cảnh báo thử","notes":"Quan sát thực địa"}}
        ]}
        """.data(using: .utf8))
        let preview = try CommunityImportParser.preview(
            data: data,
            fileName: "broken.geojson",
            submitter: "admin",
            existing: []
        )
        XCTAssertTrue(preview.candidates.isEmpty)
        XCTAssertEqual(preview.issues.count, 1)
        XCTAssertTrue(preview.issues[0].message.contains("Thiếu hình học"))
    }

    func testModerationLifecycleOnlyPublishesApprovedRecords() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("community-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let store = CommunityContributionStore(
            storageURL: temporaryURL,
            loadPersistedData: false
        )
        let contribution = makeContribution()
        XCTAssertTrue(store.submit(contribution).isValid)
        XCTAssertEqual(store.pending.count, 1)
        XCTAssertTrue(store.approvedAlerts(
            near: CLLocationCoordinate2D(latitude: 10.7769, longitude: 106.7009)
        ).isEmpty)

        store.approve(id: contribution.id, reviewer: "admin")
        XCTAssertEqual(store.pending.count, 0)
        XCTAssertEqual(store.approved.count, 1)
        let alert = try XCTUnwrap(store.approvedAlerts(
            near: CLLocationCoordinate2D(latitude: 10.7769, longitude: 106.7009)
        ).first)
        XCTAssertEqual(alert.message, "Cấm dừng và đỗ xe")
        XCTAssertEqual(alert.source, "Cộng đồng VietDrive · đã kiểm duyệt")
    }

    func testStoreRejectsSourceAlreadyBundledInVietDrive() {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("community-duplicate-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let store = CommunityContributionStore(
            storageURL: temporaryURL,
            loadPersistedData: false
        )
        var contribution = makeContribution()
        contribution.sourceReference = "https://www.openstreetmap.org/node/10796963965"
        let result = store.submit(contribution)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors, ["Nguồn này đã có trong dữ liệu VietDrive"])
    }

    private func makeContribution() -> CommunityContribution {
        CommunityContribution(
            kind: .roadSign,
            signCode: "P130",
            warningText: "Cấm dừng và đỗ xe",
            geometry: .point(latitude: 10.7769, longitude: 106.7009),
            sourceReference: "https://www.openstreetmap.org/node/987654",
            notes: "Ảnh chụp tại giao lộ",
            submitter: "tester"
        )
    }

    func testApprovedAlertsRespectTimeHeadingAndActiveRoute() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = CommunityContributionStore(storageURL: file, loadPersistedData: false)
        var contribution = makeContribution()
        contribution.conditional = "no @ (Mo-Fr 06:00-09:00,16:00-20:00)"
        contribution.sourceReference = "https://example.org/community-time"
        XCTAssertTrue(store.submit(contribution).isValid)
        store.approve(id: contribution.id, reviewer: "test")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Ho_Chi_Minh"))
        let active = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 17)))
        let inactive = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 12)))
        let anchor = try XCTUnwrap(contribution.anchor)
        let behind = CLLocationCoordinate2D(latitude: anchor.latitude - 0.002, longitude: anchor.longitude)
        XCTAssertEqual(store.approvedAlerts(near: behind, heading: 0, speedKmh: 40, at: active, calendar: calendar).count, 1)
        XCTAssertTrue(store.approvedAlerts(near: behind, heading: 0, speedKmh: 40, at: inactive, calendar: calendar).isEmpty)
        XCTAssertTrue(store.approvedAlerts(near: behind, heading: 180, speedKmh: 40, at: active, calendar: calendar).isEmpty)
        let coordinates = [CLLocationCoordinate2D(latitude: anchor.latitude - 0.005, longitude: anchor.longitude + 0.002),
                           CLLocationCoordinate2D(latitude: anchor.latitude + 0.005, longitude: anchor.longitude + 0.002)]
        let distances = RouteProgressEngine.cumulativeDistances(for: coordinates)
        let parallel = NavigationRoute(distanceMeters: distances.last!, durationSeconds: 100,
                                       coordinates: coordinates, cumulativeDistances: distances, steps: [])
        XCTAssertTrue(store.approvedAlerts(near: behind, heading: 0, speedKmh: 40,
                                           route: parallel, at: active, calendar: calendar).isEmpty)
    }
}
