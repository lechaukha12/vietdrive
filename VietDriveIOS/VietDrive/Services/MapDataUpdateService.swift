import CryptoKit
import Foundation
import SQLite3

final class MapDataUpdateService {
    private static let supportedDatabaseContract = "vn.vietdrive.map-data"
    private static let supportedDatabaseContractVersion = 1
    private static let supportedDatabaseSchemaVersion = 6

    private struct Manifest: Decodable {
        struct Database: Decodable {
            let url: URL
            let bytes: Int
            let sha256: String
        }

        let schemaVersion: Int
        let databaseContract: String
        let databaseContractVersion: Int
        let databaseSchemaVersion: Int
        let datasetVersion: String
        let minimumAppVersion: String
        let database: Database
    }

    let manifestURL: URL?

    var isConfigured: Bool { manifestURL != nil }

    init(bundle: Bundle = .main) {
        let value = bundle.object(forInfoDictionaryKey: "VietDriveDataManifestURL") as? String
        manifestURL = value.flatMap(URL.init(string:)).flatMap {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil
        }
    }

    func checkForUpdate(currentVersion: String) async throws -> String {
        guard let manifestURL else {
            throw MapDataUpdateError.notConfigured
        }
        let (manifestData, response) = try await URLSession.shared.data(from: manifestURL)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw MapDataUpdateError.server
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.schemaVersion == 1 else { throw MapDataUpdateError.unsupportedManifest }
        guard manifest.databaseContract == Self.supportedDatabaseContract,
              manifest.databaseContractVersion == Self.supportedDatabaseContractVersion,
              manifest.databaseSchemaVersion == Self.supportedDatabaseSchemaVersion else {
            throw MapDataUpdateError.unsupportedDatabase
        }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard Self.compareVersions(appVersion, manifest.minimumAppVersion) != .orderedAscending else {
            throw MapDataUpdateError.appUpdateRequired
        }
        guard manifest.datasetVersion > currentVersion else { return "Dữ liệu đang là bản mới nhất." }

        let (temporaryURL, downloadResponse) = try await URLSession.shared.download(from: manifest.database.url)
        guard let downloadHTTP = downloadResponse as? HTTPURLResponse,
              (200..<300).contains(downloadHTTP.statusCode) else {
            throw MapDataUpdateError.server
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue == manifest.database.bytes else {
            throw MapDataUpdateError.sizeMismatch
        }
        let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(manifest.database.sha256) == .orderedSame else {
            throw MapDataUpdateError.checksumMismatch
        }
        guard Self.isValidSQLite(at: temporaryURL, manifest: manifest) else {
            throw MapDataUpdateError.invalidDatabase
        }

        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("VietDrive/Data", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = base.appendingPathComponent("map_data.sqlite")
        let backup = base.appendingPathComponent("map_database_previous.sqlite")
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: destination, to: backup)
        }
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: destination)
            }
            throw error
        }
        UserDefaults.standard.set(destination.path, forKey: "activeMapDatabasePath")
        UserDefaults.standard.set(manifest.datasetVersion, forKey: "activeMapDatasetVersion")
        return "Đã tải dữ liệu \(manifest.datasetVersion). Khởi động lại app để áp dụng."
    }

    private static func isValidSQLite(at url: URL, manifest: Manifest) -> Bool {
        var database: OpaquePointer?
        defer { if let database { sqlite3_close(database) } }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return false
        }
        guard scalarText(database, "PRAGMA integrity_check;") == "ok",
              scalarInt(database, "PRAGMA user_version;") == supportedDatabaseSchemaVersion,
              scalarText(database, "SELECT value FROM metadata WHERE key='contract_id';") == supportedDatabaseContract,
              scalarInt(database, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='contract_version';") == supportedDatabaseContractVersion,
              scalarInt(database, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='schema_version';") == manifest.databaseSchemaVersion,
              scalarText(database, "SELECT value FROM metadata WHERE key='dataset_version';") == manifest.datasetVersion,
              scalarInt(database, "SELECT COUNT(*) FROM map_data_points;") > 0,
              scalarInt(database, "SELECT COUNT(*) FROM map_data_road_links;") > 0 else { return false }
        let requiredColumns = scalarInt(database, """
            SELECT COUNT(*) FROM pragma_table_info('map_data_road_links')
            WHERE name IN ('road_serial_number', 'provider_road_id', 'inline_road_name',
                           'direction_1_name_id', 'direction_2_name_id',
                           'direction_1_speed_kmh', 'direction_2_speed_kmh', 'geometry_json');
            """)
        return requiredColumns == 8
    }

    private static func scalarInt(_ database: OpaquePointer?, _ query: String) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func scalarText(_ database: OpaquePointer?, _ query: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private static func compareVersions(_ left: String, _ right: String) -> ComparisonResult {
        left.compare(right, options: .numeric)
    }
}

enum MapDataUpdateError: LocalizedError {
    case notConfigured
    case server
    case unsupportedManifest
    case unsupportedDatabase
    case appUpdateRequired
    case sizeMismatch
    case checksumMismatch
    case invalidDatabase

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Chưa cấu hình máy chủ cập nhật dữ liệu."
        case .server: "Máy chủ dữ liệu không phản hồi hợp lệ."
        case .unsupportedManifest: "Phiên bản manifest chưa được hỗ trợ."
        case .unsupportedDatabase: "Database không tương thích với phiên bản app này."
        case .appUpdateRequired: "Cần cập nhật app trước khi cài gói dữ liệu này."
        case .sizeMismatch: "Kích thước database tải về không khớp."
        case .checksumMismatch: "Checksum database không khớp."
        case .invalidDatabase: "Database tải về không vượt qua kiểm tra toàn vẹn."
        }
    }
}
