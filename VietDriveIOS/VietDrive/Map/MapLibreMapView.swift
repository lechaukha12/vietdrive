import CoreLocation
import MapLibre
import SwiftUI
import UIKit

struct MapLibreMapView: UIViewRepresentable {
    private static var didConfigureAmbientCache = false
    let snapshot: DriveSnapshot
    let alerts: [DriveAlert]
    let roads: [RoadOverlay]
    let followUser: Bool
    let cameraRevision: Int
    let destination: CLLocationCoordinate2D?
    let routeViewportRevision: Int
    let showGuidanceMascot: Bool
    let isNightMode: Bool
    let onUserInteraction: () -> Void
    let onViewportChanged: (CLLocationCoordinate2D, Double) -> Void
    let onAlertSelected: (DriveAlert) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onUserInteraction: onUserInteraction,
            onViewportChanged: onViewportChanged,
            onAlertSelected: onAlertSelected
        )
    }

    func makeUIView(context: Context) -> MLNMapView {
        if !Self.didConfigureAmbientCache {
            Self.didConfigureAmbientCache = true
            MLNOfflineStorage.shared.setMaximumAmbientCacheSize(150 * 1_024 * 1_024) { error in
                if let error { print("VietDrive: không thể cấu hình map cache: \(error)") }
            }
        }
        let styleURL = Self.styleURL(isNightMode: isNightMode)
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.delegate = context.coordinator
        mapView.compassView.compassVisibility = .visible
        mapView.showsScale = false
        mapView.showsUserLocation = !snapshot.isDemo
        mapView.tintColor = UIColor(DriveTheme.cyan)
        mapView.contentInset = UIEdgeInsets(top: 112, left: 0, bottom: 132, right: 0)
        mapView.setCenter(snapshot.coordinate, zoomLevel: 15.2, animated: false)
        context.coordinator.update(
            snapshot: snapshot,
            alerts: alerts,
            roads: roads,
            cameraRevision: cameraRevision,
            destination: destination,
            routeViewportRevision: routeViewportRevision,
            showGuidanceMascot: showGuidanceMascot,
            isNightMode: isNightMode,
            in: mapView,
            follow: true
        )
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        mapView.showsUserLocation = !snapshot.isDemo
        context.coordinator.update(
            snapshot: snapshot,
            alerts: alerts,
            roads: roads,
            cameraRevision: cameraRevision,
            destination: destination,
            routeViewportRevision: routeViewportRevision,
            showGuidanceMascot: showGuidanceMascot,
            isNightMode: isNightMode,
            in: mapView,
            follow: followUser
        )
    }

    private static func styleURL(isNightMode: Bool) -> URL? {
        URL(string: isNightMode
            ? "https://tiles.openfreemap.org/styles/dark"
            : "https://tiles.openfreemap.org/styles/liberty")
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private var alertAnnotations: [AlertMapAnnotation] = []
        private var roadAnnotations: [MLNPolyline] = []
        private var vehicleAnnotation: VehicleMapAnnotation?
        private var destinationAnnotation: DestinationMapAnnotation?
        private var guidanceMascotAnnotation: GuidanceMascotAnnotation?
        private weak var vehicleMascotView: VehicleMascotAnnotationView?
        private var lastAlertSignature = ""
        private var lastRoadSignature = ""
        private var lastCoordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        private var lastCameraRevision = -1
        private var lastRouteViewportRevision = -1
        private var lastNightMode: Bool?
        private let onUserInteraction: () -> Void
        private let onViewportChanged: (CLLocationCoordinate2D, Double) -> Void
        private let onAlertSelected: (DriveAlert) -> Void
        private var viewportWorkItem: DispatchWorkItem?

        init(
            onUserInteraction: @escaping () -> Void,
            onViewportChanged: @escaping (CLLocationCoordinate2D, Double) -> Void,
            onAlertSelected: @escaping (DriveAlert) -> Void
        ) {
            self.onUserInteraction = onUserInteraction
            self.onViewportChanged = onViewportChanged
            self.onAlertSelected = onAlertSelected
        }

        func update(
            snapshot: DriveSnapshot,
            alerts: [DriveAlert],
            roads: [RoadOverlay],
            cameraRevision: Int,
            destination: CLLocationCoordinate2D?,
            routeViewportRevision: Int,
            showGuidanceMascot: Bool,
            isNightMode: Bool,
            in mapView: MLNMapView,
            follow: Bool
        ) {
            if lastNightMode != isNightMode {
                mapView.styleURL = MapLibreMapView.styleURL(isNightMode: isNightMode)
                lastNightMode = isNightMode
            }
            let unclutteredAlerts = (spatiallySeparated(
                alerts.filter { $0.kind == .camera },
                minimumDistance: 100,
                limit: 28
            ) + spatiallySeparated(
                alerts.filter { $0.kind == .speedLimit },
                minimumDistance: 65,
                limit: 24
            ) + spatiallySeparated(
                alerts.filter { $0.kind != .camera && $0.kind != .speedLimit },
                minimumDistance: 65,
                limit: 18
            )).sorted { $0.id < $1.id }
            let signature = unclutteredAlerts.map {
                "\($0.id):\($0.kind.rawValue):\($0.speedLimit):\($0.coordinate.latitude):\($0.coordinate.longitude):\($0.assetName ?? ""):\($0.message)"
            }.joined(separator: ",")
            if signature != lastAlertSignature {
                if !alertAnnotations.isEmpty { mapView.removeAnnotations(alertAnnotations) }
                alertAnnotations = unclutteredAlerts.map {
                    let annotation = AlertMapAnnotation()
                    annotation.coordinate = $0.coordinate
                    annotation.title = $0.kind.title
                    annotation.subtitle = $0.message
                    annotation.kind = $0.kind
                    annotation.speedLimit = $0.speedLimit
                    annotation.assetName = $0.assetName
                    annotation.alert = $0
                    return annotation
                }
                mapView.addAnnotations(alertAnnotations)
                lastAlertSignature = signature
            } else {
                for (annotation, alert) in zip(alertAnnotations, unclutteredAlerts) {
                    annotation.alert = alert
                    annotation.subtitle = alert.message
                }
            }

            let roadSignature = roads.map { road in
                let first = road.coordinates.first
                let last = road.coordinates.last
                return "\(road.id):\(road.coordinates.count):\(first?.latitude ?? 0):\(last?.longitude ?? 0)"
            }.joined(separator: ",")
            if roadSignature != lastRoadSignature {
                if !roadAnnotations.isEmpty { mapView.removeAnnotations(roadAnnotations) }
                roadAnnotations = roads.compactMap { road in
                    var coordinates = road.coordinates
                    guard coordinates.count >= 2 else { return nil }
                    if road.isPrimaryRoute {
                        return PrimaryRoutePolyline(
                            coordinates: &coordinates,
                            count: UInt(coordinates.count)
                        )
                    }
                    return MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
                }
                mapView.addAnnotations(roadAnnotations)
                lastRoadSignature = roadSignature
            }

            if let destination {
                if let destinationAnnotation {
                    destinationAnnotation.coordinate = destination
                } else {
                    let annotation = DestinationMapAnnotation()
                    annotation.coordinate = destination
                    annotation.title = "Điểm đến"
                    destinationAnnotation = annotation
                    mapView.addAnnotation(annotation)
                }
            } else if let destinationAnnotation {
                mapView.removeAnnotation(destinationAnnotation)
                self.destinationAnnotation = nil
            }

            updateGuidanceMascot(
                snapshot: snapshot,
                show: showGuidanceMascot,
                in: mapView
            )

            if snapshot.isDemo {
                if let vehicleAnnotation {
                    vehicleAnnotation.coordinate = snapshot.coordinate
                } else {
                    let annotation = VehicleMapAnnotation()
                    annotation.coordinate = snapshot.coordinate
                    vehicleAnnotation = annotation
                    mapView.addAnnotation(annotation)
                }
            } else if let vehicleAnnotation {
                mapView.removeAnnotation(vehicleAnnotation)
                self.vehicleAnnotation = nil
            }

            if routeViewportRevision != lastRouteViewportRevision,
               let primaryRoute = roads.first(where: { $0.isPrimaryRoute }) {
                fit(primaryRoute.coordinates, in: mapView)
                lastRouteViewportRevision = routeViewportRevision
            }

            let moved = abs(snapshot.coordinate.latitude - lastCoordinate.latitude) > 0.00001 ||
                abs(snapshot.coordinate.longitude - lastCoordinate.longitude) > 0.00001
            if follow, moved || cameraRevision != lastCameraRevision {
                mapView.setCenter(
                    snapshot.coordinate,
                    zoomLevel: max(mapView.zoomLevel, 15.2),
                    direction: snapshot.heading,
                    animated: lastCoordinate.latitude != 0
                )
                lastCoordinate = snapshot.coordinate
                lastCameraRevision = cameraRevision
            }
            vehicleMascotView?.configure(
                heading: snapshot.heading,
                mapDirection: mapView.direction,
                moving: snapshot.speedKmh > 3
            )
        }

        func mapView(_ mapView: MLNMapView, regionWillChangeAnimated animated: Bool) {
            let isGesture = mapView.gestureRecognizers?.contains {
                $0.state == .began || $0.state == .changed
            } == true
            if isGesture {
                DispatchQueue.main.async { [onUserInteraction] in
                    onUserInteraction()
                }
            }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            scheduleViewportQuery(for: mapView)
        }

        func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
            scheduleViewportQuery(for: mapView)
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let alert = (annotation as? AlertMapAnnotation)?.alert else { return }
            onAlertSelected(alert)
        }

        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            if annotation is VehicleMapAnnotation {
                return reusableImage(in: mapView, identifier: "vehicle") {
                    Self.makeVehicleImage()
                }
            }
            if annotation is DestinationMapAnnotation {
                return reusableImage(in: mapView, identifier: "destination") {
                    Self.makeDestinationImage()
                }
            }
            guard let alert = annotation as? AlertMapAnnotation else { return nil }
            if let assetName = alert.assetName {
                return reusableImage(
                    in: mapView,
                    identifier: "road-sign-\(assetName)"
                ) {
                    Self.makeRoadSignImage(assetName: assetName)
                }
            }
            let identifier = alert.speedLimit > 0
                ? "\(alert.kind.rawValue)-\(alert.speedLimit)"
                : alert.kind.rawValue
            return reusableImage(in: mapView, identifier: identifier) {
                Self.makeAlertImage(kind: alert.kind, speedLimit: alert.speedLimit)
            }
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if annotation is VehicleMapAnnotation || annotation is MLNUserLocation {
                let identifier = "vehicle-mascot"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    as? VehicleMascotAnnotationView)
                    ?? VehicleMascotAnnotationView(reuseIdentifier: identifier)
                vehicleMascotView = view
                view.configure(
                    heading: 0,
                    mapDirection: mapView.direction,
                    moving: false
                )
                return view
            }
            guard let cue = annotation as? GuidanceMascotAnnotation else { return nil }
            let identifier = "guidance-mascot"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                as? GuidanceMascotAnnotationView)
                ?? GuidanceMascotAnnotationView(reuseIdentifier: identifier)
            view.configure(modifier: cue.modifier, cueType: cue.cueType)
            return view
        }

        func mapView(
            _ mapView: MLNMapView,
            strokeColorForShapeAnnotation annotation: MLNShape
        ) -> UIColor {
            if annotation is PrimaryRoutePolyline {
                return UIColor(DriveTheme.cyan)
            }
            return UIColor(DriveTheme.mint).withAlphaComponent(0.46)
        }

        func mapView(
            _ mapView: MLNMapView,
            lineWidthForPolylineAnnotation annotation: MLNPolyline
        ) -> CGFloat {
            annotation is PrimaryRoutePolyline ? 7 : 3
        }

        func mapView(
            _ mapView: MLNMapView,
            alphaForShapeAnnotation annotation: MLNShape
        ) -> CGFloat {
            annotation is PrimaryRoutePolyline ? 0.96 : 0.58
        }

        private func fit(
            _ coordinates: [CLLocationCoordinate2D],
            in mapView: MLNMapView
        ) {
            guard let first = coordinates.first else { return }
            var minLatitude = first.latitude
            var maxLatitude = first.latitude
            var minLongitude = first.longitude
            var maxLongitude = first.longitude
            for coordinate in coordinates.dropFirst() {
                minLatitude = min(minLatitude, coordinate.latitude)
                maxLatitude = max(maxLatitude, coordinate.latitude)
                minLongitude = min(minLongitude, coordinate.longitude)
                maxLongitude = max(maxLongitude, coordinate.longitude)
            }
            let bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: minLatitude, longitude: minLongitude),
                ne: CLLocationCoordinate2D(latitude: maxLatitude, longitude: maxLongitude)
            )
            mapView.setVisibleCoordinateBounds(
                bounds,
                edgePadding: UIEdgeInsets(top: 180, left: 42, bottom: 250, right: 42),
                animated: true,
                completionHandler: nil
            )
        }

        private func reusableImage(
            in mapView: MLNMapView,
            identifier: String,
            make: () -> UIImage
        ) -> MLNAnnotationImage {
            if let reused = mapView.dequeueReusableAnnotationImage(withIdentifier: identifier) {
                return reused
            }
            return MLNAnnotationImage(image: make(), reuseIdentifier: identifier)
        }

        private func updateGuidanceMascot(
            snapshot: DriveSnapshot,
            show: Bool,
            in mapView: MLNMapView
        ) {
            guard show,
                  let coordinate = snapshot.mascotCueCoordinate,
                  snapshot.mascotCueDistanceMeters >= 18,
                  snapshot.mascotCueDistanceMeters <= 1_200 else {
                if let guidanceMascotAnnotation {
                    mapView.removeAnnotation(guidanceMascotAnnotation)
                    self.guidanceMascotAnnotation = nil
                }
                return
            }
            if let guidanceMascotAnnotation {
                let needsRefresh = guidanceMascotAnnotation.modifier != snapshot.mascotCueModifier
                    || guidanceMascotAnnotation.cueType != snapshot.mascotCueType
                guidanceMascotAnnotation.coordinate = coordinate
                guidanceMascotAnnotation.modifier = snapshot.mascotCueModifier
                guidanceMascotAnnotation.cueType = snapshot.mascotCueType
                if needsRefresh {
                    mapView.removeAnnotation(guidanceMascotAnnotation)
                    mapView.addAnnotation(guidanceMascotAnnotation)
                }
            } else {
                let annotation = GuidanceMascotAnnotation()
                annotation.coordinate = coordinate
                annotation.title = snapshot.mascotCueType == "curve"
                    ? "Mây chỉ đường cong"
                    : "Mây chỉ chỗ rẽ"
                annotation.modifier = snapshot.mascotCueModifier
                annotation.cueType = snapshot.mascotCueType
                guidanceMascotAnnotation = annotation
                mapView.addAnnotation(annotation)
            }
        }

        private func spatiallySeparated(
            _ candidates: [DriveAlert],
            minimumDistance: CLLocationDistance,
            limit: Int
        ) -> [DriveAlert] {
            var selected: [DriveAlert] = []
            for candidate in candidates {
                let location = CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
                let isSeparated = selected.allSatisfy { existing in
                    location.distance(from: CLLocation(
                        latitude: existing.latitude,
                        longitude: existing.longitude
                    )) >= minimumDistance
                }
                if isSeparated { selected.append(candidate) }
                if selected.count == limit { break }
            }
            return selected
        }

        private func scheduleViewportQuery(for mapView: MLNMapView) {
            viewportWorkItem?.cancel()
            let center = mapView.centerCoordinate
            let bounds = mapView.visibleCoordinateBounds
            let centerLocation = CLLocation(
                latitude: center.latitude,
                longitude: center.longitude
            )
            let radius = max(
                centerLocation.distance(from: CLLocation(
                    latitude: bounds.sw.latitude,
                    longitude: bounds.sw.longitude
                )),
                centerLocation.distance(from: CLLocation(
                    latitude: bounds.ne.latitude,
                    longitude: bounds.ne.longitude
                ))
            )
            let work = DispatchWorkItem { [onViewportChanged] in
                onViewportChanged(center, radius)
            }
            viewportWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        private static func makeAlertImage(kind: AlertKind, speedLimit: Int) -> UIImage {
            let size = CGSize(width: 28, height: 28)
            return UIGraphicsImageRenderer(size: size).image { context in
                let color = UIColor(DriveTheme.alertColor(kind))
                context.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.32).cgColor)
                let body = UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 24, height: 24))
                UIColor(DriveTheme.ink).withAlphaComponent(0.90).setFill()
                body.fill()
                color.setStroke()
                body.lineWidth = 2
                body.stroke()

                if (kind == .speedLimit || kind == .camera), speedLimit > 0 {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 11, weight: .black),
                        .foregroundColor: UIColor.white
                    ]
                    let text = "\(speedLimit)" as NSString
                    let textSize = text.size(withAttributes: attributes)
                    text.draw(at: CGPoint(x: 14 - textSize.width / 2, y: 14 - textSize.height / 2), withAttributes: attributes)
                } else {
                    let symbol = UIImage(systemName: kind.iconName)?.withTintColor(color, renderingMode: .alwaysOriginal)
                    symbol?.draw(in: CGRect(x: 8, y: 8, width: 12, height: 12))
                }
            }
        }

        private static func makeRoadSignImage(assetName: String) -> UIImage {
            let size = CGSize(width: 36, height: 36)
            return UIGraphicsImageRenderer(size: size).image { context in
                context.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 2),
                    blur: 4,
                    color: UIColor.black.withAlphaComponent(0.30).cgColor
                )
                let background = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 34, height: 34))
                UIColor.white.withAlphaComponent(0.96).setFill()
                background.fill()
                if let sign = UIImage(named: assetName) {
                    let targetArea = CGRect(x: 5, y: 5, width: 26, height: 26)
                    let signSize = sign.size
                    if signSize.width > 0, signSize.height > 0 {
                        let scale = min(targetArea.width / signSize.width, targetArea.height / signSize.height)
                        let renderWidth = signSize.width * scale
                        let renderHeight = signSize.height * scale
                        let renderX = targetArea.midX - (renderWidth / 2)
                        let renderY = targetArea.midY - (renderHeight / 2)
                        sign.draw(in: CGRect(x: renderX, y: renderY, width: renderWidth, height: renderHeight))
                    } else {
                        sign.draw(in: targetArea)
                    }
                }
            }
        }

        private static func makeVehicleImage() -> UIImage {
            let size = CGSize(width: 64, height: 72)
            return UIGraphicsImageRenderer(size: size).image { context in
                context.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 3),
                    blur: 8,
                    color: UIColor(DriveTheme.cyan).withAlphaComponent(0.48).cgColor
                )
                UIImage(named: "MascotMayDriving")?.draw(
                    in: CGRect(x: 5, y: 4, width: 54, height: 62)
                )
            }
        }

        private static func makeDestinationImage() -> UIImage {
            let size = CGSize(width: 52, height: 60)
            return UIGraphicsImageRenderer(size: size).image { context in
                context.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 5),
                    blur: 9,
                    color: UIColor.black.withAlphaComponent(0.45).cgColor
                )
                let circle = CGRect(x: 5, y: 3, width: 42, height: 42)
                UIColor(DriveTheme.ink).setFill()
                UIBezierPath(ovalIn: circle).fill()
                UIColor(DriveTheme.cyan).setStroke()
                let border = UIBezierPath(ovalIn: circle)
                border.lineWidth = 3
                border.stroke()
                let symbol = UIImage(systemName: "flag.checkered")?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                symbol?.draw(in: CGRect(x: 16, y: 14, width: 20, height: 20))
                context.cgContext.setShadow(offset: .zero, blur: 0)
                let pointer = UIBezierPath()
                pointer.move(to: CGPoint(x: 20, y: 44))
                pointer.addLine(to: CGPoint(x: 26, y: 57))
                pointer.addLine(to: CGPoint(x: 32, y: 44))
                pointer.close()
                UIColor(DriveTheme.cyan).setFill()
                pointer.fill()
            }
        }
    }
}

private final class AlertMapAnnotation: MLNPointAnnotation {
    var kind: AlertKind = .hazard
    var speedLimit = 0
    var assetName: String?
    var alert: DriveAlert?
}

private final class VehicleMapAnnotation: MLNPointAnnotation {}
private final class DestinationMapAnnotation: MLNPointAnnotation {}
private final class GuidanceMascotAnnotation: MLNPointAnnotation {
    var modifier = ""
    var cueType = ""
}
private final class PrimaryRoutePolyline: MLNPolyline {}

private final class GuidanceMascotAnnotationView: MLNAnnotationView {
    private let halo = UIView()
    private let mascot = UIImageView()
    private let arrowBadge = UIImageView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 88, height: 94)
        centerOffset = CGVector(dx: 0, dy: -42)
        isOpaque = false

        halo.frame = CGRect(x: 8, y: 3, width: 72, height: 72)
        halo.backgroundColor = UIColor.white.withAlphaComponent(0.96)
        halo.layer.cornerRadius = 36
        halo.layer.borderWidth = 3
        halo.layer.borderColor = UIColor(DriveTheme.pink).cgColor
        halo.layer.shadowColor = UIColor.black.cgColor
        halo.layer.shadowOpacity = 0.20
        halo.layer.shadowRadius = 8
        halo.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(halo)

        mascot.frame = CGRect(x: 12, y: 5, width: 64, height: 66)
        mascot.contentMode = .scaleAspectFit
        addSubview(mascot)

        arrowBadge.frame = CGRect(x: 54, y: 59, width: 28, height: 28)
        arrowBadge.contentMode = .scaleAspectFit
        arrowBadge.tintColor = UIColor(DriveTheme.pink)
        arrowBadge.backgroundColor = .white
        arrowBadge.layer.cornerRadius = 14
        arrowBadge.layer.borderWidth = 2
        arrowBadge.layer.borderColor = UIColor.white.cgColor
        addSubview(arrowBadge)

        let pointer = CAShapeLayer()
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 36, y: 71))
        path.addLine(to: CGPoint(x: 44, y: 93))
        path.addLine(to: CGPoint(x: 52, y: 71))
        path.close()
        pointer.path = path.cgPath
        pointer.fillColor = UIColor(DriveTheme.pink).cgColor
        layer.insertSublayer(pointer, at: 0)

        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = -2
        bob.toValue = 4
        bob.duration = 0.65
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(bob, forKey: "mascot-bob")

        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.94
        pulse.toValue = 1.06
        pulse.duration = 0.72
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        halo.layer.add(pulse, forKey: "cue-pulse")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(modifier: String, cueType: String) {
        mascot.image = UIImage(named: "MascotMayTurn")
        let pointsRight = modifier.contains("right")
        mascot.transform = pointsRight
            ? CGAffineTransform(scaleX: -1, y: 1)
            : .identity
        let symbol: String
        if cueType == "curve" {
            symbol = "point.topleft.down.to.point.bottomright.curvepath"
        } else if modifier.contains("uturn") {
            symbol = "arrow.uturn.backward.circle.fill"
        } else {
            symbol = pointsRight ? "arrow.turn.up.right" : "arrow.turn.up.left"
        }
        arrowBadge.image = UIImage(systemName: symbol)?.withRenderingMode(.alwaysTemplate)
        arrowBadge.transform = cueType == "curve" && pointsRight
            ? CGAffineTransform(scaleX: -1, y: 1)
            : .identity
    }
}

private final class VehicleMascotAnnotationView: MLNUserLocationAnnotationView {
    private let glow = UIView()
    private let imageView = UIImageView(image: UIImage(named: "MascotMayDriving"))
    private var isAnimatingMovement = false

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 68, height: 76)
        centerOffset = CGVector(dx: 0, dy: -3)
        isOpaque = false

        glow.frame = CGRect(x: 8, y: 9, width: 52, height: 52)
        glow.backgroundColor = UIColor(DriveTheme.cyan).withAlphaComponent(0.20)
        glow.layer.cornerRadius = 26
        glow.layer.borderWidth = 2
        glow.layer.borderColor = UIColor.white.withAlphaComponent(0.88).cgColor
        glow.layer.shadowColor = UIColor(DriveTheme.cyan).cgColor
        glow.layer.shadowOpacity = 0.55
        glow.layer.shadowRadius = 9
        addSubview(glow)

        imageView.frame = CGRect(x: 5, y: 2, width: 58, height: 68)
        imageView.contentMode = .scaleAspectFit
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowOpacity = 0.22
        imageView.layer.shadowRadius = 4
        imageView.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(imageView)

        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.88
        pulse.toValue = 1.12
        pulse.duration = 0.85
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        glow.layer.add(pulse, forKey: "gps-glow")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func update() {
        super.update()
        guard let mapView, let userLocation else { return }
        let heading = userLocation.heading?.trueHeading
            ?? userLocation.heading?.magneticHeading
            ?? mapView.direction
        configure(
            heading: heading,
            mapDirection: mapView.direction,
            moving: (userLocation.location?.speed ?? 0) > 0.8
        )
    }

    func configure(heading: Double, mapDirection: CLLocationDirection, moving: Bool) {
        let relativeHeading = (heading - mapDirection) * .pi / 180
        transform = CGAffineTransform(rotationAngle: relativeHeading)
        guard moving != isAnimatingMovement else { return }
        isAnimatingMovement = moving
        imageView.layer.removeAnimation(forKey: "driving-suspension")
        guard moving else { return }
        let suspension = CABasicAnimation(keyPath: "transform.translation.y")
        suspension.fromValue = -1.2
        suspension.toValue = 1.6
        suspension.duration = 0.24
        suspension.autoreverses = true
        suspension.repeatCount = .infinity
        suspension.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageView.layer.add(suspension, forKey: "driving-suspension")
    }
}
