import CoreLocation
import Foundation
import QuartzCore

/// Presentation geometry only. Never feeds speed matching, routing, or alert eligibility.
struct DrivingSceneRoad: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    var name = ""
    var highway = ""
    var lanes: Int?
    /// nil = unknown, 0 = both directions, 1/-1 = along/against stored geometry.
    var direction: Int?
    var bridge = false
    var tunnel = false
    var layer = 0

    var width: Double {
        if let lanes { return Double(min(6, max(1, lanes))) * 3.2 + 1 }
        switch highway {
        case "motorway", "trunk": return 11
        case "primary", "secondary": return 9
        case "service", "living_street": return 5
        default: return 7
        }
    }
}

struct DrivingScenePoint: Equatable {
    var x: Double
    var z: Double
    static func + (a: Self, b: Self) -> Self { .init(x: a.x + b.x, z: a.z + b.z) }
    static func - (a: Self, b: Self) -> Self { .init(x: a.x - b.x, z: a.z - b.z) }
    static func * (a: Self, b: Double) -> Self { .init(x: a.x * b, z: a.z * b) }
    var length: Double { hypot(x, z) }
}

struct DrivingScene {
    struct Road: Identifiable {
        let source: DrivingSceneRoad
        let points: [DrivingScenePoint]
        var id: String { source.id }
    }
    struct Junction {
        let point: DrivingScenePoint
        let radius: Double
        var distanceMeters = 0.0
        var left = false
        var right = false
        var interchange = false
    }
    let roads: [Road]
    let primaryID: String?
    let ahead: [DrivingScenePoint]
    let junctions: [Junction]
    let primaryWidth: Double
    let primaryLanes: Int?
    let primaryLayer: Int
    let allowsOncoming: Bool
    let currentStructure: String?
    var primaryHighway = ""
    var sampleKey = ""
    var connectedIDs: Set<String> = []
    var events: [DrivingSceneEvent] = []
    var allowsPedestrians: Bool {
        ["residential", "living_street", "tertiary", "secondary", "primary", "unclassified", "service"].contains(primaryHighway)
            && currentStructure == nil
    }
    static let empty = DrivingScene(roads: [], primaryID: nil, ahead: [], junctions: [],
                                   primaryWidth: 7, primaryLanes: nil, primaryLayer: 0, allowsOncoming: false,
                                   currentStructure: nil)

    var isLocated: Bool { primaryID != nil }
    var curve: Double {
        guard let point = point(ahead: 35, lateral: 0) else { return 0 }
        return max(-18, min(18, atan2(point.x, max(1, point.z)) * 180 / .pi))
    }
    var aheadLength: Double {
        zip(ahead, ahead.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
    }

    static func local(_ coordinate: CLLocationCoordinate2D, origin: CLLocationCoordinate2D,
                      heading: Double) -> DrivingScenePoint {
        let north = (coordinate.latitude - origin.latitude) * 111_195
        let east = (coordinate.longitude - origin.longitude) * 111_195 * cos(origin.latitude * .pi / 180)
        let radians = heading * .pi / 180
        return .init(x: east * cos(radians) - north * sin(radians),
                     z: north * cos(radians) + east * sin(radians))
    }

    static func make(roads input: [DrivingSceneRoad], origin: CLLocationCoordinate2D,
                     heading: Double, hasGPS: Bool) -> Self {
        guard hasGPS, CLLocationCoordinate2DIsValid(origin), origin.latitude.isFinite,
              origin.longitude.isFinite, heading.isFinite else { return .empty }
        let localRoads = input.compactMap { road -> Road? in
            let raw = road.coordinates.filter {
                CLLocationCoordinate2DIsValid($0) && $0.latitude.isFinite && $0.longitude.isFinite
            }.map { local($0, origin: origin, heading: heading) }
            var points: [DrivingScenePoint] = []
            for point in raw where points.last.map({ (point - $0).length > 0.15 }) ?? true { points.append(point) }
            return points.count >= 2 ? Road(source: road, points: points) : nil
        }
        var closest: (road: Road, segment: Int, anchor: DrivingScenePoint, reversed: Bool, score: Double)?
        for road in localRoads {
            for index in 0..<(road.points.count - 1) {
                let a = road.points[index], b = road.points[index + 1], delta = b - a
                guard delta.length > 0.1 else { continue }
                let t = max(0, min(1, -(a.x * delta.x + a.z * delta.z) / pow(delta.length, 2)))
                let anchor = a + delta * t
                let alignment = atan2(abs(delta.x), abs(delta.z)) * 180 / .pi
                guard anchor.length <= 32, alignment <= 50 else { continue }
                if let direction = road.source.direction, direction != 0,
                   (direction > 0) != (delta.z > 0) { continue }
                let score = anchor.length + alignment * 0.15 + (road.id.hasPrefix("osm-") ? 2 : 0)
                if closest == nil || score < closest!.score {
                    closest = (road, index, anchor, delta.z < 0, score)
                }
            }
        }
        guard let closest else { return .empty }
        let source = closest.road.source
        // A lane-centred camera is illustrative; it is never written back as a GPS fix.
        let laneOffset = source.direction == 0 ? source.width * 0.23 : 0
        let anchor = closest.anchor + DrivingScenePoint(x: laneOffset, z: 0)
        let primaryPoints = closest.road.points.map { $0 - anchor }
        var ahead: [DrivingScenePoint] = [closest.anchor - anchor]
        if closest.reversed {
            ahead += Array(primaryPoints[...closest.segment].reversed())
        } else {
            ahead += Array(primaryPoints[(closest.segment + 1)...])
        }
        // Continue only across an unambiguous geometric connection; stop at ambiguous forks.
        var used = Set([source.id])
        for _ in 0..<20 {
            guard ahead.count >= 2, let end = ahead.last,
                  aheadLength(ahead) < 450 else { break }
            let tangent = end - ahead[ahead.count - 2]
            let candidates = localRoads.filter {
                !used.contains($0.id) && $0.source.layer == source.layer
                    && $0.source.bridge == source.bridge && $0.source.tunnel == source.tunnel
            }
                .compactMap { road -> (Road, [DrivingScenePoint], Double)? in
                    let points = road.points.map { $0 - anchor }
                    // A short firmware link may end inside a longer OSM polyline, not at its endpoint.
                    var best: ([DrivingScenePoint], Double)?
                    for index in 0..<(points.count - 1) {
                        let a = points[index], delta = points[index + 1] - a
                        let t = max(0, min(1, ((end - a).x * delta.x + (end - a).z * delta.z) / max(0.01, delta.length * delta.length)))
                        let join = a + delta * t
                        guard (join - end).length <= 3 else { continue }
                        let reversed = tangent.x * delta.x + tangent.z * delta.z < 0
                        if let direction = road.source.direction, direction != 0,
                           (direction < 0) != reversed { continue }
                        let forward = reversed ? delta * -1 : delta
                        let cosine = (tangent.x * forward.x + tangent.z * forward.z) / max(0.01, tangent.length * forward.length)
                        let angle = acos(max(-1, min(1, cosine))) * 180 / .pi
                        let tail = reversed ? Array(points[...index].reversed()) : Array(points[(index + 1)...])
                        let continuation = [join] + tail.filter { ($0 - join).length > 0.15 }
                        guard angle < 55, aheadLength(continuation) > 3 else { continue }
                        if best == nil || angle < best!.1 { best = (continuation, angle) }
                    }
                    return best.map { (road, $0.0, $0.1) }
                }.sorted { abs($0.2 - $1.2) < 0.1 ? aheadLength($0.1) > aheadLength($1.1) : $0.2 < $1.2 }
            // Firmware + OSM can represent the same continuation. That is not a fork.
            var unique: [(Road, [DrivingScenePoint], Double)] = []
            for candidate in candidates {
                let duplicate = unique.contains { existing in
                    guard abs(existing.2 - candidate.2) < 5 else { return false }
                    let shorter = aheadLength(existing.1) < aheadLength(candidate.1) ? existing.1 : candidate.1
                    let longer = aheadLength(existing.1) < aheadLength(candidate.1) ? candidate.1 : existing.1
                    return shorter.allSatisfy { point in
                        zip(longer, longer.dropFirst()).contains { a, b in
                            DrivingSceneReader.distance(point, to: a, b) < 2
                        }
                    }
                }
                if !duplicate { unique.append(candidate) }
            }
            guard let next = unique.first,
                  unique.count == 1 || unique[1].2 - next.2 >= 22 else { break }
            ahead += next.1.dropFirst()
            used.insert(next.0.id)
        }
        let shifted: [Road] = localRoads.map { road in
            Road(source: road.source, points: road.points.map { $0 - anchor })
        }
        let visible: [Road] = shifted.filter { road in
            zip(road.points, road.points.dropFirst()).contains { a, b in
                max(a.z, b.z) >= -15 && min(a.z, b.z) <= 500
                    && max(a.x, b.x) >= -180 && min(a.x, b.x) <= 180
            }
        }
        let ranked: [Road] = visible.sorted { first, second in
            if first.id == source.id && second.id != source.id { return true }
            if second.id == source.id { return false }
            let firstDistance = zip(first.points, first.points.dropFirst()).map { DrivingSceneReader.distance(.init(x: 0, z: 0), to: $0, $1) }.min() ?? .infinity
            let secondDistance = zip(second.points, second.points.dropFirst()).map { DrivingSceneReader.distance(.init(x: 0, z: 0), to: $0, $1) }.min() ?? .infinity
            return firstDistance == secondDistance ? first.id < second.id : firstDistance < secondDistance
        }
        let candidates = Array(ranked.prefix(24))
        let roads = candidates.filter { road in
            guard road.id.hasPrefix("firmware-") else { return true }
            // Paint one road surface, not two slightly offset firmware/OSM outlines.
            return !candidates.contains { other in
                guard other.id.hasPrefix("osm-"), other.source.layer == road.source.layer,
                      other.source.bridge == road.source.bridge, other.source.tunnel == road.source.tunnel else { return false }
                return road.points.allSatisfy { point in
                    zip(other.points, other.points.dropFirst()).contains { DrivingSceneReader.distance(point, to: $0, $1) < 3 }
                }
            }
        }
        var junctions: [Junction] = []
        for road in shifted where !used.contains(road.id) && road.source.layer == source.layer
            && road.source.bridge == source.bridge && road.source.tunnel == source.tunnel {
            var along = 0.0
            for (a, b) in zip(ahead, ahead.dropFirst()) {
                defer { along += (b - a).length }
                for (c, d) in zip(road.points, road.points.dropFirst()) {
                    let first = b - a, second = d - c
                    let cosine = abs(first.x * second.x + first.z * second.z) / max(0.01, first.length * second.length)
                    guard cosine < 0.94 else { continue }
                    if let point = intersection(a, b, c, d), point.z > -4,
                       along + (point - a).length < 650 {
                        let normal = DrivingScenePoint(x: first.z / first.length, z: -first.x / first.length)
                        let lateral = [c - point, d - point].map { $0.x * normal.x + $0.z * normal.z }
                        let left = lateral.contains { $0 < -2.5 }, right = lateral.contains { $0 > 2.5 }
                        guard left || right else { continue }
                        let interchange = road.source.highway.hasSuffix("_link")
                            && ["motorway", "trunk"].contains(source.highway)
                        if let index = junctions.firstIndex(where: { ($0.point - point).length < 10 }) {
                            junctions[index].left = junctions[index].left || left
                            junctions[index].right = junctions[index].right || right
                            junctions[index].interchange = junctions[index].interchange || interchange
                        } else {
                            junctions.append(.init(point: point, radius: road.source.width * 0.8 + 3,
                                                   distanceMeters: along + (point - a).length,
                                                   left: left, right: right, interchange: interchange))
                        }
                    }
                }
            }
        }
        var events = junctions.map { junction in
            // Stable geographic key, not a camera-relative distance that changes at every fix.
            let point = junction.point + anchor
            let radians = heading * .pi / 180
            let latitude = origin.latitude + (point.z * cos(radians) - point.x * sin(radians)) / 111_195
            let longitude = origin.longitude + (point.x * cos(radians) + point.z * sin(radians))
                / (111_195 * cos(origin.latitude * .pi / 180))
            return DrivingSceneEvent(id: "junction-\(Int((latitude * 100_000).rounded()))-\(Int((longitude * 100_000).rounded()))",
                              kind: junction.interchange ? .interchange : .junction,
                              distanceMeters: junction.distanceMeters, left: junction.left, right: junction.right)
        }
        if source.bridge || source.tunnel {
            events.append(.init(id: "current-structure", kind: source.tunnel ? .tunnel : .bridge,
                                distanceMeters: 0, lengthMeters: min(220, aheadLength(ahead))))
        } else {
            // A structure must connect to the forward path and agree with its direction.
            // A bridge crossing overhead must never become a bridge-entry event.
            for road in shifted where road.source.bridge || road.source.tunnel {
                var entries: [Double] = []
                for (endpoint, neighbour) in [(road.points.first!, road.points[1]),
                                              (road.points.last!, road.points[road.points.count - 2])] {
                    var along = 0.0
                    for (a, b) in zip(ahead, ahead.dropFirst()) {
                        defer { along += (b - a).length }
                        let delta = b - a, direction = neighbour - endpoint
                        let alignment = abs(delta.x * direction.x + delta.z * direction.z)
                            / max(0.01, delta.length * direction.length)
                        guard alignment > 0.8, DrivingSceneReader.distance(endpoint, to: a, b) < 5 else { continue }
                        let t = max(0, min(1, ((endpoint - a).x * delta.x + (endpoint - a).z * delta.z)
                                          / max(0.01, delta.length * delta.length)))
                        let distance = along + delta.length * t
                        if distance > 8 && distance < 650 { entries.append(distance) }
                    }
                }
                if let distance = entries.min(),
                   !events.contains(where: { $0.kind == (road.source.tunnel ? .tunnel : .bridge) && abs($0.distanceMeters - distance) < 20 }) {
                    events.append(.init(id: "structure-\(road.id)", kind: road.source.tunnel ? .tunnel : .bridge,
                                        distanceMeters: distance, lengthMeters: min(180, aheadLength(road.points))))
                }
            }
        }
        return .init(roads: roads, primaryID: source.id, ahead: ahead, junctions: junctions,
                     primaryWidth: source.width, primaryLanes: source.lanes, primaryLayer: source.layer,
                     allowsOncoming: source.direction == 0,
                     currentStructure: source.tunnel ? "Đường hầm" : source.bridge ? "Cầu / đường trên cao" : nil,
                     primaryHighway: source.highway,
                     sampleKey: "\(origin.latitude)/\(origin.longitude)/\(heading)", connectedIDs: used,
                     events: events.sorted { $0.distanceMeters < $1.distanceMeters })
    }

    private static func aheadLength(_ points: [DrivingScenePoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
    }

    static func intersection(_ a: DrivingScenePoint, _ b: DrivingScenePoint,
                             _ c: DrivingScenePoint, _ d: DrivingScenePoint) -> DrivingScenePoint? {
        let r = b - a, s = d - c
        let cross = r.x * s.z - r.z * s.x
        guard abs(cross) > 0.001 else { return nil }
        let q = c - a
        let t = (q.x * s.z - q.z * s.x) / cross
        let u = (q.x * r.z - q.z * r.x) / cross
        guard (0...1).contains(t), (0...1).contains(u) else { return nil }
        return a + r * t
    }

    func point(ahead distance: Double, lateral: Double) -> DrivingScenePoint? {
        guard distance.isFinite, distance >= 0, lateral.isFinite else { return nil }
        var remaining = distance
        for (a, b) in zip(ahead, ahead.dropFirst()) {
            let delta = b - a, length = delta.length
            guard length > 0.01 else { continue }
            if remaining <= length {
                return a + delta * (remaining / length)
                    + DrivingScenePoint(x: delta.z / length * lateral, z: -delta.x / length * lateral)
            }
            remaining -= length
        }
        return nil
    }

    static func project(_ point: DrivingScenePoint, size: CGSize, layer: Int = 0) -> CGPoint? {
        guard point.x.isFinite, point.z.isFinite, point.z >= -12, point.z <= 550,
              size.width > 0, size.height > 0 else { return nil }
        let scale = 95 / (95 + point.z)
        return CGPoint(x: size.width * (0.5 + point.x / 16 * scale),
                       y: size.height * (0.06 + 0.88 * scale - Double(layer) * 0.012 * scale))
    }

    func roadsidePosition(distance: Double, size: CGSize) -> CGPoint? {
        guard distance.isFinite, distance >= 0 else { return nil }
        return DrivingRibbon.point(distance: distance, side: 1.15, size: size)
    }

    /// GPU homography of the ground plane. Bounded visual prediction, never a GPS fix.
    static func groundTransform(advance: Double, size: CGSize) -> CATransform3D {
        guard advance.isFinite, size.height > 0 else { return CATransform3DIdentity }
        let meters = max(0, min(24, advance))
        let c = -meters / (95 * size.height * 0.88)
        let d = 1 + meters * 0.06 / (95 * 0.88)
        var transform = CATransform3DIdentity
        transform.m21 = size.width * 0.5 * c
        transform.m41 = size.width * 0.5 * (d - 1)
        transform.m22 = 1 + size.height * 0.06 * c
        transform.m42 = size.height * 0.06 * (d - 1)
        transform.m24 = c
        transform.m44 = d
        return transform
    }
}

/// An upcoming place, not road mesh or a navigation instruction. No fake/random events.
struct DrivingSceneEvent: Identifiable, Equatable {
    enum Kind: String { case junction, interchange, bridge, tunnel, toll }
    let id: String
    let kind: Kind
    var distanceMeters: Double
    var left = false
    var right = false
    var lengthMeters = 100.0
    var title: String {
        switch kind {
        case .junction: left && right ? "Ngã tư" : "Ngã ba"
        case .interchange: "Nút giao"
        case .bridge: distanceMeters <= 1 ? "Đang qua cầu" : "Cầu phía trước"
        case .tunnel: distanceMeters <= 1 ? "Đang qua hầm" : "Đường hầm"
        case .toll: "Trạm thu phí"
        }
    }
    var cutsRoad: Bool { kind == .junction || kind == .interchange }
    var presentationPriority: Int {
        switch kind {
        case .toll: 3
        case .bridge, .tunnel: 2
        case .interchange: 1
        case .junction: 0
        }
    }
}

/// Approved symbolic road: the camera and corridor never rotate or curve with the map.
enum DrivingRibbon {
    static let leftLaneCenter = -0.5
    static let rightLaneCenter = 0.5

    /// Mazda occupies the right half of the same two-lane ribbon used by traffic and signs.
    static func egoFrame(size: CGSize, maximumWidth: Double = 88) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              maximumWidth.isFinite, maximumWidth > 0 else { return .zero }
        let baseY = size.height * 0.89
        let depth = (baseY / size.height - 0.04) / 0.92
        let center = point(depth: depth, side: rightLaneCenter, size: size)
        let edge = point(depth: depth, side: 1, size: size)
        // Keep the entire rectangle within the right lane, even at its narrower upper end.
        let slope = size.width * 0.365 / (size.height * 0.92)
        let laneCap = (edge.x - center.x - 2) / (0.5 + slope * 0.89)
        let width = max(0, min(maximumWidth, 88, size.height * 0.36, size.width * 0.23, laneCap))
        return CGRect(x: center.x - width / 2, y: baseY - width * 0.89, width: width, height: width)
    }

    /// Move only decorative captions to clear traffic signs. Actual sign data/layout is unchanged.
    static func captionFrame(preferredY: Double, width: Double, size: CGSize,
                             excluding rects: [CGRect]) -> CGRect? {
        guard preferredY.isFinite, width.isFinite, size.width.isFinite, size.height.isFinite,
              size.width >= 100, size.height >= 40 else { return nil }
        let width = min(size.width - 16, max(20, width))
        for offset in [0.0, -24, 24, -48, 48, -72, 72, -96, 96] {
            let y = max(14, min(size.height - 14, preferredY + offset))
            let frame = CGRect(x: (size.width - width) / 2, y: y - 10, width: width, height: 20)
            if !rects.contains(where: { $0.insetBy(dx: -5, dy: -4).intersects(frame) }) { return frame }
        }
        return nil
    }

    static func depth(_ distance: Double) -> Double { 220 / (220 + max(0, distance)) }
    static func point(depth: Double, side: Double, size: CGSize) -> CGPoint {
        .init(x: size.width * (0.5 + side * (0.035 + depth * 0.365)),
              y: size.height * (0.04 + depth * 0.92))
    }
    static func point(distance: Double, side: Double, size: CGSize) -> CGPoint {
        point(depth: depth(distance), side: side, size: size)
    }
    static func visibleEvents(_ events: [DrivingSceneEvent]) -> [DrivingSceneEvent] {
        let valid = events.filter { $0.distanceMeters.isFinite && (0...650).contains($0.distanceMeters) }
            .sorted {
                if $0.presentationPriority != $1.presentationPriority { return $0.presentationPriority > $1.presentationPriority }
                return $0.distanceMeters == $1.distanceMeters ? $0.id < $1.id : $0.distanceMeters < $1.distanceMeters
            }
        var result: [DrivingSceneEvent] = []
        for event in valid {
            guard !result.contains(where: { abs($0.distanceMeters - event.distanceMeters) < 24 }) else { continue }
            result.append(event)
        }
        return Array(result.sorted { $0.distanceMeters < $1.distanceMeters }.prefix(2))
    }
}

struct DrivingSceneFrameClock {
    private(set) var receivedAt = Date()
    mutating func receive(at date: Date = Date()) { receivedAt = date }
    func advance(speed: Int, running: Bool, at date: Date = Date()) -> Double {
        guard running else { return 0 }
        return min(24, Double(max(0, min(180, speed))) / 3.6 * min(1, max(0, date.timeIntervalSince(receivedAt))))
    }
}

/// Continuous distance clock prevents jumps when speed changes or the app resumes.
struct DrivingSceneMotion {
    private(set) var distance = 0.0
    private(set) var date: Date
    private(set) var rate = 0.0
    init(date: Date = Date()) { self.date = date }
    func value(at now: Date) -> Double { distance + max(0, now.timeIntervalSince(date)) * rate }
    mutating func update(speed: Int, running: Bool, now: Date = Date()) {
        distance = value(at: now).truncatingRemainder(dividingBy: 10_000)
        date = now
        rate = running ? Double(max(0, min(180, speed))) / 3.6 : 0
    }
}
