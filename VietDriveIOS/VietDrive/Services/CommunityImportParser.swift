import CoreLocation
import Foundation

enum CommunityImportError: LocalizedError {
    case unsupportedFormat
    case malformedFile(String)
    case tooManyRecords(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "VietDrive chỉ hỗ trợ GeoJSON, JSON và CSV."
        case .malformedFile(let reason):
            "Không đọc được tệp: \(reason)"
        case .tooManyRecords(let count):
            "Tệp có \(count) bản ghi, vượt giới hạn 5.000 bản ghi mỗi lần nhập."
        }
    }
}

enum CommunityImportParser {
    static let maximumRecordsPerImport = 5_000
    private static let vietnamBounds = (
        minLatitude: 8.15,
        maxLatitude: 23.50,
        minLongitude: 102.00,
        maxLongitude: 109.60
    )

    static func preview(
        data: Data,
        fileName: String,
        submitter: String,
        existing: [CommunityContribution],
        knownSourceReferences: Set<String> = []
    ) throws -> CommunityImportPreview {
        let lowercasedName = fileName.lowercased()
        let raw: [(row: Int, contribution: CommunityContribution)]
        if lowercasedName.hasSuffix(".geojson") || lowercasedName.hasSuffix(".json") {
            raw = try decodeJSON(data, fileName: fileName, submitter: submitter)
        } else if lowercasedName.hasSuffix(".csv") {
            raw = try decodeCSV(data, fileName: fileName, submitter: submitter)
        } else {
            throw CommunityImportError.unsupportedFormat
        }
        guard raw.count <= maximumRecordsPerImport else {
            throw CommunityImportError.tooManyRecords(raw.count)
        }

        var accepted: [CommunityContribution] = []
        var issues: [CommunityImportIssue] = []
        var duplicateCount = 0
        for item in raw {
            let validation = validate(item.contribution)
            if !validation.isValid {
                issues.append(CommunityImportIssue(
                    row: item.row,
                    message: validation.errors.joined(separator: " · ")
                ))
                continue
            }
            if (!item.contribution.sourceReference.isEmpty && knownSourceReferences.contains(
                item.contribution.sourceReference.lowercased()
            )) || isDuplicate(item.contribution, in: existing + accepted) {
                duplicateCount += 1
                continue
            }
            accepted.append(item.contribution)
        }
        return CommunityImportPreview(
            fileName: fileName,
            candidates: accepted,
            issues: issues,
            duplicateCount: duplicateCount
        )
    }

    static func validate(_ contribution: CommunityContribution) -> ContributionValidationResult {
        var errors: [String] = []
        let text = contribution.warningText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count < 3 { errors.append("Thiếu nội dung cảnh báo") }
        if text.count > 180 { errors.append("Nội dung cảnh báo quá dài") }
        if contribution.geometry.coordinates.isEmpty {
            errors.append("Thiếu hình học")
        } else {
            let minimumCount = contribution.geometry.type == .point ? 1 : 2
            if contribution.geometry.coordinates.count < minimumCount {
                errors.append("Hình học không đủ điểm")
            }
            for coordinate in contribution.geometry.coordinates {
                guard coordinate.count >= 2 else {
                    errors.append("Tọa độ không hợp lệ")
                    break
                }
                let longitude = coordinate[0]
                let latitude = coordinate[1]
                guard longitude.isFinite, latitude.isFinite,
                      vietnamBounds.minLongitude...vietnamBounds.maxLongitude ~= longitude,
                      vietnamBounds.minLatitude...vietnamBounds.maxLatitude ~= latitude else {
                    errors.append("Tọa độ nằm ngoài Việt Nam")
                    break
                }
            }
        }
        if contribution.kind == .roadSign || contribution.kind == .speedLimit {
            let code = contribution.signCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if code.isEmpty { errors.append("Thiếu mã biển báo") }
            if !code.isEmpty, code.range(
                of: #"^[A-Z][0-9]{2,3}[a-z]?(?:\.[0-9]{2,3})?$"#,
                options: .regularExpression
            ) == nil {
                errors.append("Mã biển báo không đúng định dạng")
            }
        }
        if contribution.conditional.count > 240 { errors.append("Điều kiện thời gian quá dài") }
        if !contribution.sourceReference.isEmpty,
           URL(string: contribution.sourceReference)?.scheme?.hasPrefix("http") != true {
            errors.append("Liên kết nguồn không hợp lệ")
        }
        if contribution.sourceReference.isEmpty,
           contribution.notes.trimmingCharacters(in: .whitespacesAndNewlines).count < 5 {
            errors.append("Cần liên kết nguồn hoặc ghi chú bằng chứng")
        }
        return ContributionValidationResult(errors: Array(Set(errors)).sorted())
    }

    static func isDuplicate(
        _ candidate: CommunityContribution,
        in existing: [CommunityContribution]
    ) -> Bool {
        if !candidate.sourceReference.isEmpty,
           existing.contains(where: {
               !$0.sourceReference.isEmpty &&
               $0.sourceReference.caseInsensitiveCompare(candidate.sourceReference) == .orderedSame
           }) {
            return true
        }
        guard let anchor = candidate.anchor else { return false }
        let location = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
        return existing.contains { item in
            guard item.kind == candidate.kind,
                  item.signCode.caseInsensitiveCompare(candidate.signCode) == .orderedSame,
                  let other = item.anchor else { return false }
            return location.distance(from: CLLocation(
                latitude: other.latitude,
                longitude: other.longitude
            )) <= 8
        }
    }

    private static func decodeJSON(
        _ data: Data,
        fileName: String,
        submitter: String
    ) throws -> [(Int, CommunityContribution)] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CommunityImportError.malformedFile(error.localizedDescription)
        }
        guard let root = object as? [String: Any],
              root["type"] as? String == "FeatureCollection",
              let features = root["features"] as? [[String: Any]] else {
            throw CommunityImportError.malformedFile("JSON phải là GeoJSON FeatureCollection")
        }
        return features.enumerated().map { index, feature in
            (index + 1, contribution(
                geometryObject: feature["geometry"],
                properties: feature["properties"] as? [String: Any] ?? [:],
                fileName: fileName,
                submitter: submitter
            ))
        }
    }

    private static func decodeCSV(
        _ data: Data,
        fileName: String,
        submitter: String
    ) throws -> [(Int, CommunityContribution)] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CommunityImportError.malformedFile("CSV không dùng UTF-8")
        }
        let rows = parseCSV(text)
        guard let headers = rows.first, !headers.isEmpty else {
            throw CommunityImportError.malformedFile("CSV không có tiêu đề cột")
        }
        return rows.dropFirst().enumerated().compactMap { offset, values in
            guard values.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                return nil
            }
            var fields: [String: String] = [:]
            for (index, header) in headers.enumerated() where index < values.count {
                fields[header.trimmingCharacters(in: .whitespacesAndNewlines)] = values[index]
            }
            return (offset + 2, contribution(
                csvFields: fields,
                fileName: fileName,
                submitter: submitter
            ))
        }
    }

    private static func contribution(
        geometryObject: Any?,
        properties: [String: Any],
        fileName: String,
        submitter: String
    ) -> CommunityContribution {
        let geometry = decodeGeometry(geometryObject)
            ?? ContributionGeometry(type: .point, coordinates: [])
        return makeContribution(
            properties: properties,
            geometry: geometry,
            fileName: fileName,
            submitter: submitter
        )
    }

    private static func contribution(
        csvFields: [String: String],
        fileName: String,
        submitter: String
    ) -> CommunityContribution {
        let geometry: ContributionGeometry?
        if let latitude = Double(csvFields["latitude"] ?? ""),
           let longitude = Double(csvFields["longitude"] ?? "") {
            geometry = .point(latitude: latitude, longitude: longitude)
        } else if let raw = csvFields["geometry_json"],
                  let data = raw.data(using: .utf8),
                  let coordinates = try? JSONSerialization.jsonObject(with: data) as? [[Double]] {
            geometry = ContributionGeometry(type: .lineString, coordinates: coordinates)
        } else {
            geometry = nil
        }
        let resolvedGeometry = geometry
            ?? ContributionGeometry(type: .point, coordinates: [])
        var properties: [String: Any] = csvFields
        for key in ["parking_rules", "truck_rules", "conditional_rules"] {
            if let raw = csvFields[key],
               let data = raw.data(using: .utf8),
               let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                properties[key] = dictionary
            }
        }
        if properties["restriction"] == nil {
            properties["restriction"] = csvFields["restriction_type"]
        }
        if properties["source_ref"] == nil {
            properties["source_ref"] = csvFields["osm_url"]
        }
        return makeContribution(
            properties: properties,
            geometry: resolvedGeometry,
            fileName: fileName,
            submitter: submitter
        )
    }

    private static func decodeGeometry(_ object: Any?) -> ContributionGeometry? {
        guard let geometry = object as? [String: Any],
              let typeText = geometry["type"] as? String,
              let type = ContributionGeometryType(rawValue: typeText) else { return nil }
        if type == .point,
           let coordinates = geometry["coordinates"] as? [Double] {
            return ContributionGeometry(type: .point, coordinates: [coordinates])
        }
        if type == .lineString,
           let coordinates = geometry["coordinates"] as? [[Double]] {
            return ContributionGeometry(type: .lineString, coordinates: coordinates)
        }
        return nil
    }

    private static func makeContribution(
        properties: [String: Any],
        geometry: ContributionGeometry,
        fileName: String,
        submitter: String
    ) -> CommunityContribution {
        let signCode = string(properties["sign_code"])
        let restriction = string(properties["restriction"])
        let parkingRules = dictionary(properties["parking_rules"])
        let truckRules = dictionary(properties["truck_rules"])
        let conditionalRules = dictionary(properties["conditional_rules"])
        let declaredKind = ContributionKind(rawValue: string(properties["kind"]))

        let kind: ContributionKind
        if let declaredKind {
            kind = declaredKind
        } else if TrafficSignCatalog.speedLimit(from: signCode) != nil {
            kind = .speedLimit
        } else if !signCode.isEmpty {
            kind = .roadSign
        } else if !restriction.isEmpty {
            kind = .turnRestriction
        } else if !parkingRules.isEmpty {
            kind = .parkingRestriction
        } else if !truckRules.isEmpty {
            kind = .vehicleRestriction
        } else {
            kind = .roadHazard
        }

        var warning = string(properties["warning_text"])
        if warning.isEmpty {
            switch kind {
            case .parkingRestriction:
                warning = parkingRules.values.contains(where: {
                    $0.lowercased().contains("stopping")
                }) ? "Cấm dừng và đỗ xe" : "Hạn chế đỗ xe"
            case .vehicleRestriction: warning = "Hạn chế xe tải"
            case .turnRestriction: warning = restriction.replacingOccurrences(of: "_", with: " ")
            default: warning = kind.defaultMessage
            }
        }
        let sourceReference = string(properties["source_ref"], fallback: string(properties["osm_url"]))
        let conditional = string(
            properties["conditional"],
            fallback: conditionalRules.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
        )
        let notes = string(
            properties["notes"],
            fallback: ruleDescription(parkingRules.merging(truckRules) { current, _ in current })
        )
        return CommunityContribution(
            kind: kind,
            signCode: signCode,
            warningText: warning,
            geometry: geometry,
            conditional: conditional,
            sourceReference: sourceReference,
            notes: notes.isEmpty ? "Nhập từ tệp \(fileName)" : notes,
            submitter: submitter,
            importedFileName: fileName,
            confidence: 0.55
        )
    }

    private static func dictionary(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.reduce(into: [:]) { result, item in
            result[item.key] = String(describing: item.value)
        }
    }

    private static func string(_ value: Any?, fallback: String = "") -> String {
        guard let value else { return fallback }
        let result = value as? String ?? String(describing: value)
        return result.isEmpty ? fallback : result
    }

    private static func ruleDescription(_ rules: [String: String]) -> String {
        rules.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
    }

    /// RFC 4180-style parser sufficient for exported OSM JSON fields containing
    /// commas and doubled quotes.
    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if quoted, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    quoted.toggle()
                }
            } else if character == ",", !quoted {
                row.append(field)
                field = ""
            } else if character == "\n", !quoted {
                row.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            rows.append(row)
        }
        return rows
    }
}
