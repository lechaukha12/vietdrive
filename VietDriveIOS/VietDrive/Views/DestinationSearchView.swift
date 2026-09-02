import SwiftUI
import UIKit
import MapLibre

struct DestinationSearchView: View {
    private enum Field {
        case origin
        case destination

        var title: String { self == .origin ? "Điểm bắt đầu" : "Điểm đến" }
        var symbol: String { self == .origin ? "a.circle.fill" : "b.circle.fill" }
    }

    @EnvironmentObject private var model: DriveViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissSearch) private var dismissSearch
    @State private var activeField: Field = .destination
    @State private var origin: PlaceSearchResult?
    @State private var destination: PlaceSearchResult?
    @State private var query = ""
    @State private var results: [PlaceSearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didLoadExistingRoute = false
    @State private var showMapPicker = false
    @State private var mapPickerCoordinate = CLLocationCoordinate2D(latitude: 10.7769, longitude: 106.7009)
    @AppStorage("recentDestinationPlacesV1") private var recentPlacesData = Data()
    @AppStorage("favoriteHomePlaceV1") private var homePlaceData = Data()
    @AppStorage("favoriteWorkPlaceV1") private var workPlaceData = Data()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 9) {
                    locationField(
                        field: .origin,
                        title: origin?.name ?? "Vị trí hiện tại",
                        subtitle: origin?.subtitle ?? "Dùng GPS của iPhone"
                    )
                    locationField(
                        field: .destination,
                        title: destination?.name ?? "Chọn điểm đến",
                        subtitle: destination?.subtitle ?? "Tìm địa chỉ hoặc địa danh"
                    )
                    if let destination {
                        DestinationSelectionPreview(
                            place: destination,
                            onPickOnMap: { openMapPicker(around: destination) },
                            onSaveHome: { saveFavorite(destination, asHome: true) },
                            onSaveWork: { saveFavorite(destination, asHome: false) }
                        )
                    }
                    if origin == nil, !model.canUseCurrentLocationForRouting {
                        HStack(spacing: 8) {
                            Image(systemName: model.locationAuthorizationDenied
                                ? "location.slash.fill" : "location.magnifyingglass")
                            Text(model.locationAuthorizationDenied
                                ? "Chưa có quyền vị trí. Chọn điểm bắt đầu hoặc mở Cài đặt."
                                : "Đang chờ GPS chính xác. Bạn vẫn có thể chọn điểm bắt đầu.")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if model.locationAuthorizationDenied {
                                Button("Cài đặt") { openAppSettings() }
                                    .fontWeight(.bold)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(DriveTheme.amber)
                        .padding(.horizontal, 4)
                    }
                }
                .padding(14)
                .background(DriveTheme.skySoft.opacity(0.55))

                searchContent
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let destination {
                    Button(action: planRoute) {
                        HStack(spacing: 10) {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Tìm đường")
                                    .font(.headline)
                                Text("Đến \(destination.name)")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title3)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(DriveTheme.cyan, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .disabled(origin == nil && !model.canUseCurrentLocationForRouting)
                    .opacity(origin == nil && !model.canUseCurrentLocationForRouting ? 0.5 : 1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("Lập tuyến A → B")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Tìm \(activeField.title.lowercased())"
            )
            .scrollDismissesKeyboard(.interactively)
            .submitLabel(.done)
            .onSubmit { hideKeyboard() }
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled(false)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Ẩn bàn phím") { hideKeyboard() }
                }
            }
            .onAppear {
                guard !didLoadExistingRoute else { return }
                didLoadExistingRoute = true
                origin = model.routeOrigin
                destination = model.destination
            }
            .task(id: query) { await search() }
            .sheet(isPresented: $showMapPicker) {
                MapPlacePickerView(initialCoordinate: mapPickerCoordinate) { result in
                    select(result)
                }
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count < 2 {
            suggestionsContent
        } else if isLoading && results.isEmpty {
            VStack(spacing: 12) {
                ProgressView().tint(DriveTheme.cyan)
                Text("Đang tìm trên OpenStreetMap…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, results.isEmpty {
            ContentUnavailableView(
                "Chưa thể tìm kiếm",
                systemImage: "wifi.exclamationmark",
                description: Text(errorMessage)
            )
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(results) { result in
                Button { select(result) } label: {
                    HStack(spacing: 13) {
                        Image(systemName: activeField.symbol)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(activeField == .origin ? DriveTheme.mint : DriveTheme.pink)
                            .frame(width: 38, height: 38)
                            .background(
                                (activeField == .origin ? DriveTheme.mint : DriveTheme.pink)
                                    .opacity(0.12),
                                in: Circle()
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.name)
                                .font(.body.weight(.bold))
                                .foregroundStyle(.primary)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Lưu làm Nhà", systemImage: "house.fill") {
                        saveFavorite(result, asHome: true)
                    }
                    Button("Lưu làm Cơ quan", systemImage: "briefcase.fill") {
                        saveFavorite(result, asHome: false)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var suggestionsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("CHỌN NHANH")
                    .font(.caption.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    if activeField == .origin {
                        QuickPlaceButton(
                            title: "Vị trí hiện tại",
                            subtitle: "Dùng GPS iPhone",
                            icon: "location.fill",
                            tint: DriveTheme.mint
                        ) {
                            origin = nil
                            activeField = .destination
                        }
                    }
                    if let homePlace {
                        QuickPlaceButton(
                            title: "Nhà",
                            subtitle: homePlace.name,
                            icon: "house.fill",
                            tint: DriveTheme.pink
                        ) { select(homePlace) }
                    }
                    if let workPlace {
                        QuickPlaceButton(
                            title: "Cơ quan",
                            subtitle: workPlace.name,
                            icon: "briefcase.fill",
                            tint: DriveTheme.skyDeep
                        ) { select(workPlace) }
                    }
                    QuickPlaceButton(
                        title: "Chọn trên bản đồ",
                        subtitle: "Thả ghim chính xác",
                        icon: "mappin.and.ellipse",
                        tint: DriveTheme.amber
                    ) { openMapPicker(around: destination ?? origin) }
                }

                if !recentPlaces.isEmpty {
                    Text("GẦN ĐÂY")
                        .font(.caption.weight(.bold))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(recentPlaces) { place in
                            Button { select(place) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(DriveTheme.skyDeep)
                                        .frame(width: 34, height: 34)
                                        .background(DriveTheme.skyDeep.opacity(0.10), in: Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(place.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(place.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)
                            if place.id != recentPlaces.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .padding(16)
        }
    }

    private func locationField(field: Field, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Button {
                activeField = field
                query = ""
                results = []
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: field.symbol)
                        .font(.title3.weight(.black))
                        .foregroundStyle(field == .origin ? DriveTheme.mint : DriveTheme.pink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.title.uppercased())
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.secondary)
                        Text(title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(DriveTheme.ink)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if field == .origin, origin != nil {
                Button {
                    origin = nil
                    activeField = .origin
                } label: {
                    Image(systemName: "location.fill")
                        .frame(width: 34, height: 34)
                        .background(DriveTheme.skySoft, in: Circle())
                }
                .accessibilityLabel("Dùng vị trí hiện tại")
            } else if field == .destination, destination != nil {
                Button { destination = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Xóa điểm đến")
            }
        }
        .padding(11)
        .background(.white.opacity(activeField == field ? 1 : 0.72), in: RoundedRectangle(cornerRadius: 17))
        .overlay(
            RoundedRectangle(cornerRadius: 17)
                .stroke(activeField == field ? DriveTheme.cyan : .clear, lineWidth: 1.5)
        )
    }

    private func select(_ result: PlaceSearchResult) {
        switch activeField {
        case .origin:
            origin = result
            activeField = .destination
        case .destination:
            destination = result
            remember(result)
        }
        query = ""
        results = []
        errorMessage = nil
        finishSearching()
    }

    private func planRoute() {
        guard let destination,
              origin != nil || model.canUseCurrentLocationForRouting
        else { return }
        finishSearching()
        model.planRoute(from: origin, to: destination)
        dismiss()
    }

    private func finishSearching() {
        hideKeyboard()
        dismissSearch()
    }

    private func search() async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else {
            results = []
            errorMessage = nil
            isLoading = false
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isLoading = true
            errorMessage = nil
            let found = try await model.searchDestinations(query: normalized)
            guard !Task.isCancelled else { return }
            results = found
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private var recentPlaces: [PlaceSearchResult] {
        (try? JSONDecoder().decode([PlaceSearchResult].self, from: recentPlacesData)) ?? []
    }

    private var homePlace: PlaceSearchResult? {
        try? JSONDecoder().decode(PlaceSearchResult.self, from: homePlaceData)
    }

    private var workPlace: PlaceSearchResult? {
        try? JSONDecoder().decode(PlaceSearchResult.self, from: workPlaceData)
    }

    private func remember(_ place: PlaceSearchResult) {
        var places = recentPlaces.filter { $0.id != place.id }
        places.insert(place, at: 0)
        recentPlacesData = (try? JSONEncoder().encode(Array(places.prefix(6)))) ?? Data()
    }

    private func saveFavorite(_ place: PlaceSearchResult, asHome: Bool) {
        let encoded = (try? JSONEncoder().encode(place)) ?? Data()
        if asHome {
            homePlaceData = encoded
        } else {
            workPlaceData = encoded
        }
    }

    private func openMapPicker(around place: PlaceSearchResult?) {
        if let place {
            mapPickerCoordinate = place.coordinate
        } else {
            let current = model.snapshot.coordinate
            if (-90...90).contains(current.latitude),
               (-180...180).contains(current.longitude),
               abs(current.latitude) + abs(current.longitude) > 0.001 {
                mapPickerCoordinate = current
            }
        }
        hideKeyboard()
        showMapPicker = true
    }
}

private struct QuickPlaceButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

private struct DestinationSelectionPreview: View {
    let place: PlaceSearchResult
    let onPickOnMap: () -> Void
    let onSaveHome: () -> Void
    let onSaveWork: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            DestinationPreviewMap(place: place, isNight: colorScheme == .dark)
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 8) {
                Button(action: onPickOnMap) {
                    Label("Đổi ghim", systemImage: "mappin.and.ellipse")
                }
                Menu {
                    Button("Lưu làm Nhà", systemImage: "house.fill", action: onSaveHome)
                    Button("Lưu làm Cơ quan", systemImage: "briefcase.fill", action: onSaveWork)
                } label: {
                    Image(systemName: "star.fill")
                }
            }
            .font(.caption.weight(.semibold))
            .padding(9)
            .foregroundStyle(.white)
            .background(.black.opacity(0.58), in: Capsule())
            .padding(8)
        }
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.10)))
    }
}

private struct DestinationPreviewMap: UIViewRepresentable {
    let place: PlaceSearchResult
    let isNight: Bool

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(
            frame: .zero,
            styleURL: URL(string: isNight
                ? "https://tiles.openfreemap.org/styles/dark"
                : "https://tiles.openfreemap.org/styles/liberty")
        )
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true
        update(map)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) { update(map) }

    private func update(_ map: MLNMapView) {
        map.setCenter(place.coordinate, zoomLevel: 15.4, animated: false)
        if let existing = map.annotations { map.removeAnnotations(existing) }
        let pin = MLNPointAnnotation()
        pin.coordinate = place.coordinate
        pin.title = place.name
        map.addAnnotation(pin)
    }
}

private struct MapPlacePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinate: CLLocationCoordinate2D
    let onSelect: (PlaceSearchResult) -> Void

    init(
        initialCoordinate: CLLocationCoordinate2D,
        onSelect: @escaping (PlaceSearchResult) -> Void
    ) {
        _coordinate = State(initialValue: initialCoordinate)
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            ZStack {
                InteractiveCoordinateMap(coordinate: $coordinate)
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 5) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(DriveTheme.pink)
                        .shadow(color: .black.opacity(0.28), radius: 5, y: 3)
                    Circle()
                        .fill(.black.opacity(0.20))
                        .frame(width: 12, height: 5)
                }
                .offset(y: -22)
                .allowsHitTesting(false)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        let result = PlaceSearchResult(
                            id: String(format: "picked:%.6f,%.6f", coordinate.latitude, coordinate.longitude),
                            name: "Điểm đã chọn trên bản đồ",
                            subtitle: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude),
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        )
                        onSelect(result)
                        dismiss()
                    } label: {
                        Label("Chọn vị trí này", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(DriveTheme.skyDeep, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(.regularMaterial)
            }
            .navigationTitle("Chọn trên bản đồ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
            }
        }
    }
}

private struct InteractiveCoordinateMap: UIViewRepresentable {
    @Binding var coordinate: CLLocationCoordinate2D
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(coordinate: $coordinate) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(
            frame: .zero,
            styleURL: URL(string: colorScheme == .dark
                ? "https://tiles.openfreemap.org/styles/dark"
                : "https://tiles.openfreemap.org/styles/liberty")
        )
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.setCenter(coordinate, zoomLevel: 15.2, animated: false)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.coordinate = $coordinate
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var coordinate: Binding<CLLocationCoordinate2D>

        init(coordinate: Binding<CLLocationCoordinate2D>) {
            self.coordinate = coordinate
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            coordinate.wrappedValue = mapView.centerCoordinate
        }
    }
}
