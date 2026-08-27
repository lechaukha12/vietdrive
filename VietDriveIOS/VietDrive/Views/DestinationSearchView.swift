import SwiftUI
import UIKit

struct DestinationSearchView: View {
    private enum Field {
        case origin
        case destination

        var title: String { self == .origin ? "Điểm bắt đầu" : "Điểm đến" }
        var symbol: String { self == .origin ? "a.circle.fill" : "b.circle.fill" }
    }

    @EnvironmentObject private var model: DriveViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var activeField: Field = .destination
    @State private var origin: PlaceSearchResult?
    @State private var destination: PlaceSearchResult?
    @State private var query = ""
    @State private var results: [PlaceSearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didLoadExistingRoute = false

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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tìm đường") {
                        guard let destination else { return }
                        hideKeyboard()
                        model.planRoute(from: origin, to: destination)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(destination == nil || (origin == nil && !model.canUseCurrentLocationForRouting))
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
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count < 2 {
            ContentUnavailableView(
                "Chọn \(activeField.title.lowercased())",
                systemImage: activeField.symbol,
                description: Text(
                    activeField == .origin
                        ? "Tìm một địa điểm, hoặc giữ “Vị trí hiện tại” để dùng GPS."
                        : "Nhập tên đường, địa danh hoặc địa chỉ tại Việt Nam."
                )
            )
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
            }
            .listStyle(.plain)
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
        }
        query = ""
        results = []
        errorMessage = nil
        hideKeyboard()
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
}
