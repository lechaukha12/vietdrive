import CarPlay
import Combine
import MapKit
import SwiftUI
import UIKit

/// CarPlay is a presentation client of the same route/GPS state as the phone.
/// The navigation entitlement must be granted by Apple before this scene can
/// connect on a vehicle or the CarPlay simulator.
@MainActor
@objc(CarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private weak var interfaceController: CPInterfaceController?
    private weak var carWindow: CPWindow?
    private var mapTemplate: CPMapTemplate?
    private var navigationSession: CPNavigationSession?
    private var currentManeuver: CPManeuver?
    private var lastInstruction = ""
    private var cancellables = Set<AnyCancellable>()

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        carWindow = window

        window.rootViewController = UIHostingController(rootView: CarPlayMapSurfaceView())
        window.isHidden = false

        let template = CPMapTemplate()
        template.automaticallyHidesNavigationBar = true
        template.mapButtons = [CPMapButton { _ in
            PlatformDriveCoordinator.shared.requestCarPlayRecenter()
        }]
        template.mapButtons[0].image = UIImage(systemName: "location.fill")
        mapTemplate = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)

        observeDriveState()
        refreshGuidance()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        navigationSession?.finishTrip()
        navigationSession = nil
        currentManeuver = nil
        cancellables.removeAll()
        mapTemplate = nil
        carWindow = nil
        self.interfaceController = nil
    }

    private func observeDriveState() {
        let coordinator = PlatformDriveCoordinator.shared
        Publishers.CombineLatest4(
            coordinator.$snapshot,
            coordinator.$destinationCoordinate,
            coordinator.$isNavigating,
            coordinator.$remainingDistanceMeters
        )
        .combineLatest(coordinator.$remainingDurationSeconds)
        .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] _ in self?.refreshGuidance() }
        .store(in: &cancellables)
    }

    private func refreshGuidance() {
        let coordinator = PlatformDriveCoordinator.shared
        guard coordinator.isNavigating,
              let destinationCoordinate = coordinator.destinationCoordinate,
              let mapTemplate else {
            navigationSession?.finishTrip()
            navigationSession = nil
            currentManeuver = nil
            lastInstruction = ""
            return
        }

        if navigationSession == nil {
            let originItem = MKMapItem(placemark: MKPlacemark(
                coordinate: coordinator.snapshot.coordinate
            ))
            originItem.name = "Vị trí hiện tại"
            let destinationItem = MKMapItem(placemark: MKPlacemark(
                coordinate: destinationCoordinate
            ))
            destinationItem.name = coordinator.destinationName ?? "Điểm đến"
            let routeChoice = CPRouteChoice(
                summaryVariants: [coordinator.snapshot.roadName, "Tuyến VietDrive"],
                additionalInformationVariants: ["Dẫn đường VietDrive"],
                selectionSummaryVariants: [coordinator.destinationName ?? "Điểm đến"]
            )
            let trip = CPTrip(
                origin: originItem,
                destination: destinationItem,
                routeChoices: [routeChoice]
            )
            navigationSession = mapTemplate.startNavigationSession(for: trip)
        }

        let instruction = coordinator.snapshot.nextManeuver.isEmpty
            ? "Tiếp tục đi thẳng"
            : coordinator.snapshot.nextManeuver
        let estimates = CPTravelEstimates(
            distanceRemaining: Measurement(
                value: max(0, Double(coordinator.snapshot.maneuverDistanceMeters)),
                unit: UnitLength.meters
            ),
            timeRemaining: max(0, coordinator.remainingDurationSeconds)
        )
        if currentManeuver == nil || instruction != lastInstruction {
            let maneuver = CPManeuver()
            maneuver.instructionVariants = [instruction]
            maneuver.initialTravelEstimates = estimates
            maneuver.symbolImage = maneuverSymbol(
                type: coordinator.snapshot.maneuverType,
                modifier: coordinator.snapshot.maneuverModifier
            )
            navigationSession?.upcomingManeuvers = [maneuver]
            currentManeuver = maneuver
            lastInstruction = instruction
        }
        if let currentManeuver {
            navigationSession?.updateEstimates(estimates, for: currentManeuver)
        }
    }

    private func maneuverSymbol(type: String, modifier: String) -> UIImage? {
        let name: String
        if type == "roundabout" || type == "rotary" {
            name = "arrow.trianglehead.2.clockwise.rotate.90"
        } else if modifier.contains("left") {
            name = "arrow.turn.up.left"
        } else if modifier.contains("right") {
            name = "arrow.turn.up.right"
        } else if modifier == "uturn" {
            name = "arrow.uturn.backward"
        } else {
            name = "arrow.up"
        }
        return UIImage(systemName: name)
    }
}

@MainActor
private struct CarPlayMapSurfaceView: View {
    @ObservedObject private var coordinator = PlatformDriveCoordinator.shared

    var body: some View {
        MapLibreMapView(
            snapshot: coordinator.snapshot,
            alerts: coordinator.alerts,
            roads: coordinator.roads,
            followUser: true,
            cameraRevision: coordinator.mapRevision,
            destination: coordinator.destinationCoordinate,
            routeViewportRevision: coordinator.mapRevision,
            showGuidanceMascot: false,
            isNightMode: false,
            displayMode: .drive3D,
            onUserInteraction: {},
            onViewportChanged: { _, _ in },
            onAlertSelected: { _ in }
        )
        .ignoresSafeArea()
    }
}
