import CoreLocation
import Foundation
import SQLite3

@MainActor
final class CommunityContributionStore: ObservableObject {
    static let shared = CommunityContributionStore()

    @Published private(set) var contributions: [CommunityContribution] = []
    @Published private(set) var lastError = ""

    private let storageURL: URL
    private var cachedBuiltinSourceReferences: Set<String>?

    init(storageURL: URL? = nil, loadPersistedData: Bool = true) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("VietDrive", isDirectory: true)
            self.storageURL = directory.appendingPathComponent("community_contributions.json")
        }
        if loadPersistedData { load() }
    }

    var pending: [CommunityContribution] {
        contributions.filter { $0.status == .pending }.sorted { $0.createdAt > $1.createdAt }
    }

    var approved: [CommunityContribution] {
        contributions.filter { $0.status == .approved }.sorted { $0.createdAt > $1.createdAt }
    }

    var rejected: [CommunityContribution] {
        contributions.filter { $0.status == .rejected }.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func submit(_ contribution: CommunityContribution) -> ContributionValidationResult {
        let validation = CommunityImportParser.validate(contribution)
        guard validation.isValid else { return validation }
        if !contribution.sourceReference.isEmpty,
           builtinSourceReferences().contains(contribution.sourceReference.lowercased()) {
            return ContributionValidationResult(errors: ["Nguồn này đã có trong dữ liệu VietDrive"])
        }
        guard !CommunityImportParser.isDuplicate(contribution, in: contributions) else {
            return ContributionValidationResult(errors: ["Đề xuất này trùng dữ liệu đã gửi"])
        }
        var pendingContribution = contribution
        pendingContribution.status = .pending
        pendingContribution.reviewedAt = nil
        pendingContribution.reviewer = nil
        pendingContribution.rejectionReason = nil
        contributions.append(pendingContribution)
        persist()
        return validation
    }

    func importPreview(
        data: Data,
        fileName: String,
        submitter: String
    ) throws -> CommunityImportPreview {
        try CommunityImportParser.preview(
            data: data,
            fileName: fileName,
            submitter: submitter,
            existing: contributions,
            knownSourceReferences: builtinSourceReferences()
        )
    }

    func commit(_ preview: CommunityImportPreview) {
        guard !preview.candidates.isEmpty else { return }
        contributions.append(contentsOf: preview.candidates.map { candidate in
            var pending = candidate
            pending.status = .pending
            return pending
        })
        persist()
    }

    func approve(id: UUID, reviewer: String) {
        update(id: id) { contribution in
            contribution.status = .approved
            contribution.reviewer = reviewer
            contribution.reviewedAt = Date()
            contribution.rejectionReason = nil
            contribution.confidence = max(0.70, contribution.confidence)
        }
    }

    func reject(id: UUID, reviewer: String, reason: String) {
        update(id: id) { contribution in
            contribution.status = .rejected
            contribution.reviewer = reviewer
            contribution.reviewedAt = Date()
            contribution.rejectionReason = reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Chưa đủ bằng chứng để xác minh"
                : reason
        }
    }

    func reopen(id: UUID) {
        update(id: id) { contribution in
            contribution.status = .pending
            contribution.reviewer = nil
            contribution.reviewedAt = nil
            contribution.rejectionReason = nil
        }
    }

    func approvedAlerts(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance = 1_500,
        heading: Double = 0,
        speedKmh: Int = 0,
        route: NavigationRoute? = nil,
        matchedDistanceMeters: Double? = nil,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> [DriveAlert] {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let candidates: [DriveAlert] = approved.compactMap { contribution in
            guard let anchor = contribution.anchor else { return nil }
            let distance = origin.distance(from: CLLocation(
                latitude: anchor.latitude,
                longitude: anchor.longitude
            ))
            guard distance <= radiusMeters else { return nil }
            return DriveAlert(
                id: contribution.stableAlertID,
                kind: contribution.kind.alertKind,
                speedLimit: contribution.speedLimit,
                latitude: anchor.latitude,
                longitude: anchor.longitude,
                message: contribution.warningText,
                province: "",
                distanceMeters: distance,
                signCode: contribution.signCode.isEmpty ? nil : contribution.signCode,
                assetName: contribution.assetName,
                source: "Cộng đồng VietDrive · đã kiểm duyệt",
                sourceReference: contribution.sourceReference.isEmpty
                    ? nil : contribution.sourceReference,
                confidence: contribution.confidence,
                conditional: contribution.conditional.isEmpty ? nil : contribution.conditional
            )
        }
        return OfflineAlertStore.filterDrivingAlerts(
            candidates, location: origin, heading: heading, speedKmh: speedKmh,
            route: route, matchedDistanceMeters: matchedDistanceMeters,
            radiusMeters: radiusMeters, at: date, calendar: calendar
        )
    }

    private func update(id: UUID, mutation: (inout CommunityContribution) -> Void) {
        guard let index = contributions.firstIndex(where: { $0.id == id }) else { return }
        mutation(&contributions[index])
        persist()
    }

    private func builtinSourceReferences() -> Set<String> {
        if let cachedBuiltinSourceReferences { return cachedBuiltinSourceReferences }
        guard let path = Bundle.main.path(forResource: "map_database_v2", ofType: "sqlite") else {
            cachedBuiltinSourceReferences = []
            return []
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            cachedBuiltinSourceReferences = []
            return []
        }
        defer { sqlite3_close(database) }
        let query = """
            SELECT source_ref FROM map_data_points WHERE source_ref != ''
            UNION SELECT source_ref FROM alerts WHERE source_ref IS NOT NULL AND source_ref != ''
            UNION SELECT source_ref FROM turn_restrictions WHERE source_ref != ''
            UNION SELECT source_ref FROM road_rules WHERE source_ref != '';
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            cachedBuiltinSourceReferences = []
            return []
        }
        var references: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) {
            references.insert(String(cString: value).lowercased())
        }
        cachedBuiltinSourceReferences = references
        return references
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            contributions = try decoder.decode(
                [CommunityContribution].self,
                from: Data(contentsOf: storageURL)
            )
            lastError = ""
        } catch {
            lastError = "Không đọc được hàng chờ cộng đồng: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(contributions).write(to: storageURL, options: .atomic)
            lastError = ""
        } catch {
            lastError = "Không lưu được dữ liệu cộng đồng: \(error.localizedDescription)"
        }
    }
}
