import Foundation

struct MapDataIssueReport: Codable, Identifiable, Equatable {
    let id: UUID
    let alertID: Int
    let kind: AlertKind
    let signCode: String?
    let latitude: Double
    let longitude: Double
    let message: String
    let source: String
    let reason: String
    let createdAt: Date
    var status: String
}

final class MapDataIssueStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("VietDrive", isDirectory: true)
            .appendingPathComponent("map_data_issue_reports.json")
        try? FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func reports() -> [MapDataIssueReport] {
        guard let data = try? Data(contentsOf: fileURL),
              let reports = try? JSONDecoder().decode([MapDataIssueReport].self, from: data)
        else { return [] }
        return reports.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func submit(alert: DriveAlert, reason: String) -> MapDataIssueReport {
        var reports = reports()
        let report = MapDataIssueReport(
            id: UUID(),
            alertID: alert.id,
            kind: alert.kind,
            signCode: alert.signCode,
            latitude: alert.latitude,
            longitude: alert.longitude,
            message: alert.message,
            source: alert.source,
            reason: reason,
            createdAt: Date(),
            status: "pending"
        )
        reports.insert(report, at: 0)
        if let data = try? JSONEncoder().encode(Array(reports.prefix(500))) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return report
    }
}
