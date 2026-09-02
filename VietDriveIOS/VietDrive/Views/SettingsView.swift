import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: DriveViewModel
    @EnvironmentObject private var session: AppSessionModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var communityStore = CommunityContributionStore.shared
    @AppStorage("showMascotOnMap") private var showMascotOnMap = true
    @AppStorage("reduceMascotMotion") private var reduceMascotMotion = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("autoRecordDriveTrace") private var autoRecordDriveTrace = true
    @AppStorage("liveActivitiesEnabled") private var liveActivitiesEnabled = true
    @AppStorage("mapAppearance") private var mapAppearanceRaw = MapAppearance.automatic.rawValue
    @State private var confirmOfflineMapRemoval = false
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            ZStack {
                CartoonBackground()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        accountCard
                        drivingAndAlertsSection
                        mapAndOfflineSection
                        routingSection
                        advancedSection
                        logoutButton
                        footer
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onDisappear { model.refreshLayerVisibility() }
            .onChange(of: liveActivitiesEnabled) { _, _ in
                model.refreshLiveActivityPreference()
            }
            .confirmationDialog(
                "Xóa toàn bộ vùng bản đồ offline?",
                isPresented: $confirmOfflineMapRemoval,
                titleVisibility: .visible
            ) {
                Button("Xóa toàn bộ", role: .destructive) {
                    model.removeAllOfflineMaps()
                }
                Button("Hủy", role: .cancel) {}
            } message: {
                Text("Có thể tải lại các vùng này khi cần.")
            }
        }
    }

    private var drivingAndAlertsSection: some View {
        SettingsCard(
            title: "LÁI XE & CẢNH BÁO",
            icon: "steeringwheel",
            tint: DriveTheme.pink
        ) {
            SettingsToggle(
                title: "Hiện Mây trên bản đồ",
                subtitle: "Mascot phản ứng theo tốc độ và cảnh báo",
                icon: "face.smiling.inverse",
                tint: DriveTheme.pink,
                isOn: $showMascotOnMap
            )
            SettingsToggle(
                title: "Phản hồi rung",
                subtitle: "Rung nhẹ khi có cảnh báo quan trọng",
                icon: "iphone.radiowaves.left.and.right",
                tint: DriveTheme.mint,
                isOn: $hapticsEnabled
            )
            SettingsToggle(
                title: "Live Activity & Dynamic Island",
                subtitle: "Hiện tốc độ, biển báo và chỉ dẫn khi khóa màn hình",
                icon: "platter.filled.top.iphone",
                tint: DriveTheme.skyDeep,
                isOn: $liveActivitiesEnabled
            )
            SettingsToggle(
                title: "Thông báo bằng giọng nói",
                subtitle: model.voiceDescription,
                icon: "waveform",
                tint: DriveTheme.skyDeep,
                isOn: Binding(
                    get: { model.voiceEnabled },
                    set: { model.updateVoiceEnabled($0) }
                )
            )
            Button { model.previewVoice() } label: {
                SettingsActionRow(
                    title: "Nghe thử giọng hiện tại",
                    icon: "play.fill",
                    tint: DriveTheme.pink
                )
            }
            .buttonStyle(.plain)
            .disabled(!model.voiceEnabled)
            SettingsToggle(
                title: "Giảm chuyển động",
                subtitle: "Dừng các animation lặp của mascot",
                icon: "figure.walk.motion",
                tint: DriveTheme.skyDeep,
                isOn: $reduceMascotMotion
            )
        }
    }

    private var mapAndOfflineSection: some View {
        SettingsCard(
            title: "BẢN ĐỒ & OFFLINE",
            icon: "map.fill",
            tint: DriveTheme.mint
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Giao diện bản đồ")
                    .font(.subheadline.weight(.semibold))
                Picker("Giao diện bản đồ", selection: $mapAppearanceRaw) {
                    ForEach(MapAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 10)

            SettingsToggle(
                title: "Camera giao thông",
                subtitle: "Hiện các camera đã xác minh trên bản đồ",
                icon: "camera.metering.center.weighted",
                tint: DriveTheme.danger,
                isOn: $model.showCameras
            )
            SettingsToggle(
                title: "Biển báo giao thông",
                subtitle: "Hiện biển báo vật lý và giới hạn tốc độ",
                icon: "signpost.right.and.left.fill",
                tint: DriveTheme.amber,
                isOn: $model.showRoadSigns
            )

            Button {
                let appearance = MapAppearance(rawValue: mapAppearanceRaw) ?? .automatic
                model.downloadOfflineMapAroundCurrentLocation(
                    night: appearance.isNight(systemScheme: colorScheme)
                )
            } label: {
                SettingsActionRow(
                    title: "Tải vùng hiện tại để dùng offline",
                    subtitle: model.offlineMapStatus,
                    icon: "arrow.down.circle.fill",
                    tint: DriveTheme.skyDeep
                )
            }
            .buttonStyle(.plain)

            if model.offlineMapPackCount > 0 {
                HStack(spacing: 8) {
                    Button {
                        if model.offlineMapIsDownloading {
                            model.pauseOfflineMapDownload()
                        } else {
                            model.resumeOfflineMapDownload()
                        }
                    } label: {
                        Label(
                            model.offlineMapIsDownloading ? "Tạm dừng" : "Tiếp tục",
                            systemImage: model.offlineMapIsDownloading ? "pause.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        confirmOfflineMapRemoval = true
                    } label: {
                        Label("Xóa vùng", systemImage: "trash.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption.weight(.semibold))
                .padding(.vertical, 8)
            }

            if model.offlineMapProgress > 0, model.offlineMapProgress < 1 {
                ProgressView(value: model.offlineMapProgress)
                    .tint(DriveTheme.skyDeep)
                    .padding(.bottom, 10)
            }
        }
    }

    private var routingSection: some View {
        SettingsCard(
            title: "ĐỊNH TUYẾN",
            icon: "point.bottomleft.forward.to.point.topright.scurvepath",
            tint: DriveTheme.cyan
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ưu tiên tuyến")
                    .font(.subheadline.weight(.semibold))
                Picker("Ưu tiên tuyến", selection: routeStrategyBinding) {
                    ForEach(RouteStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 10)
            SettingsToggle(
                title: "Tránh đường thu phí",
                subtitle: "Áp dụng khi máy chủ định tuyến hỗ trợ",
                icon: "creditcard.fill",
                tint: DriveTheme.amber,
                isOn: preferenceBinding(\.avoidTolls)
            )
            SettingsToggle(
                title: "Tránh đường cao tốc",
                subtitle: "Có thể làm hành trình dài hơn đáng kể",
                icon: "road.lanes",
                tint: DriveTheme.pink,
                isOn: preferenceBinding(\.avoidMotorways)
            )
            SettingsToggle(
                title: "Tránh phà",
                subtitle: "Ưu tiên tuyến đường bộ liên tục",
                icon: "ferry.fill",
                tint: DriveTheme.skyDeep,
                isOn: preferenceBinding(\.avoidFerries)
            )
        }
    }

    private var advancedSection: some View {
        SettingsCard(
            title: "NÂNG CAO & HỖ TRỢ",
            icon: "wrench.and.screwdriver.fill",
            tint: DriveTheme.amber
        ) {
            NavigationLink {
                CommunityDataHubView()
            } label: {
                SettingsActionRow(
                    title: "Đóng góp và báo lỗi dữ liệu",
                    subtitle: "\(communityStore.pending.count) mục chờ duyệt · \(model.mapIssueReportCount) báo cáo",
                    icon: "plus.bubble.fill",
                    tint: DriveTheme.pink
                )
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.snappy(duration: 0.28)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(DriveTheme.amber)
                        .frame(width: 34, height: 34)
                        .background(DriveTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    Text(showAdvanced ? "Ẩn tùy chọn nâng cao" : "Hiện tùy chọn nâng cao")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showAdvanced ? 180 : 0))
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if showAdvanced {
                Divider()
                SettingsInfoRow(
                    title: "Dữ liệu bản đồ",
                    detail: "Schema 6 · \(model.datasetVersion) · \(model.pendingReviewCount) mục chờ duyệt",
                    icon: "externaldrive.badge.checkmark",
                    tint: DriveTheme.mint
                )
                Button { model.checkForDataUpdate() } label: {
                    SettingsActionRow(
                        title: model.isCheckingDataUpdate ? "Đang kiểm tra…" : "Kiểm tra cập nhật dữ liệu",
                        subtitle: model.dataUpdateStatus.isEmpty ? nil : model.dataUpdateStatus,
                        icon: "arrow.triangle.2.circlepath",
                        tint: DriveTheme.mint
                    )
                }
                .buttonStyle(.plain)
                .disabled(!model.isDataUpdateConfigured || model.isCheckingDataUpdate)
                SettingsToggle(
                    title: "Đường đã xác thực",
                    subtitle: "Hiện lớp hình học phục vụ chẩn đoán",
                    icon: "point.topleft.down.to.point.bottomright.curvepath",
                    tint: DriveTheme.skyDeep,
                    isOn: $model.showValidatedRoads
                )
                SettingsToggle(
                    title: "Tự động ghi GPS",
                    subtitle: "Giữ tối đa 10 hành trình để tái hiện lỗi",
                    icon: "record.circle",
                    tint: DriveTheme.danger,
                    isOn: $autoRecordDriveTrace
                )
                NavigationLink {
                    DriveDiagnosticsView().environmentObject(model)
                } label: {
                    SettingsActionRow(
                        title: "Chẩn đoán và phát lại GPS",
                        icon: "stethoscope",
                        tint: DriveTheme.amber
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var accountCard: some View {
        HStack(spacing: 12) {
            MascotMayView(mood: .neutral, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.username.isEmpty ? "VietDrive" : "Xin chào, \(session.username)")
                    .font(.system(size: 18, weight: .semibold))
                Text("Trợ lý lái xe của bạn")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(DriveTheme.skyDeep)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.08)))
    }

    private var logoutButton: some View {
        Button(role: .destructive) {
            model.endUserSession()
            dismiss()
            session.logout()
        } label: {
            Label("Đăng xuất", systemImage: "rectangle.portrait.and.arrow.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DriveTheme.danger)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(.top, 2)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("VietDrive \(appVersion)")
                .font(.caption.weight(.semibold))
            Text("Vị trí chỉ dùng cho dẫn đường và cảnh báo giao thông.")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.bottom, 20)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var routeStrategyBinding: Binding<RouteStrategy> {
        Binding(
            get: { model.routePreferences.strategy },
            set: { value in
                var preferences = model.routePreferences
                preferences.strategy = value
                model.updateRoutePreferences(preferences)
            }
        )
    }

    private func preferenceBinding(_ keyPath: WritableKeyPath<RoutePreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.routePreferences[keyPath: keyPath] },
            set: { value in
                var preferences = model.routePreferences
                preferences[keyPath: keyPath] = value
                model.updateRoutePreferences(preferences)
            }
        )
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .tracking(0.65)
                .foregroundStyle(tint)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .padding(.horizontal, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .background(
                    DriveTheme.surfaceStrong.opacity(0.64),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.08)))
        }
    }
}

private struct SettingsToggle: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: $isOn).labelsHidden().tint(tint)
        }
        .padding(.vertical, 9)
    }
}

private struct SettingsActionRow: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 9)
    }
}
