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
    @AppStorage("mapAppearance") private var mapAppearanceRaw = MapAppearance.automatic.rawValue
    @State private var confirmOfflineMapRemoval = false

    var body: some View {
        NavigationStack {
            ZStack {
                CartoonBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        accountCard
                        SettingsCard(title: "TRẢI NGHIỆM", icon: "sparkles", tint: DriveTheme.pink) {
                            SettingsToggle(
                                title: "Hiện mascot trên bản đồ",
                                subtitle: "Mây phản ứng theo chỉ dẫn và cảnh báo",
                                icon: "face.smiling.inverse",
                                tint: DriveTheme.pink,
                                isOn: $showMascotOnMap
                            )
                            SettingsToggle(
                                title: "Giảm chuyển động",
                                subtitle: "Tắt các animation lặp của mascot",
                                icon: "figure.walk.motion",
                                tint: DriveTheme.skyDeep,
                                isOn: $reduceMascotMotion
                            )
                            SettingsToggle(
                                title: "Phản hồi rung",
                                subtitle: "Rung nhẹ khi có cảnh báo quan trọng",
                                icon: "iphone.radiowaves.left.and.right",
                                tint: DriveTheme.mint,
                                isOn: $hapticsEnabled
                            )
                            SettingsToggle(
                                title: "Hướng dẫn bằng giọng nói",
                                subtitle: model.voiceDescription,
                                icon: "waveform",
                                tint: DriveTheme.skyDeep,
                                isOn: Binding(
                                    get: { model.voiceEnabled },
                                    set: { model.updateVoiceEnabled($0) }
                                )
                            )
                            Button {
                                model.previewVoice()
                            } label: {
                                SettingsActionRow(
                                    title: "Nghe thử giọng hiện tại",
                                    icon: "play.fill",
                                    tint: DriveTheme.pink
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.voiceEnabled)
                        }

                        SettingsCard(title: "ĐỊNH TUYẾN", icon: "point.bottomleft.forward.to.point.topright.scurvepath", tint: DriveTheme.cyan) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ưu tiên tuyến")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(DriveTheme.ink)
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

                        SettingsCard(title: "LỚP BẢN ĐỒ", icon: "map.fill", tint: DriveTheme.mint) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Giao diện bản đồ")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(DriveTheme.ink)
                                Picker("Giao diện bản đồ", selection: $mapAppearanceRaw) {
                                    ForEach(MapAppearance.allCases) { appearance in
                                        Text(appearance.title).tag(appearance.rawValue)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                            .padding(.vertical, 10)
                            SettingsToggle(
                                title: "Camera map-data",
                                subtitle: "\(model.mapDataCameraCount) điểm camera theo chuẩn iGO",
                                icon: "camera.metering.center.weighted",
                                tint: DriveTheme.danger,
                                isOn: $model.showCameras
                            )
                            SettingsToggle(
                                title: "Biển báo & dữ liệu giao thông",
                                subtitle: "\(model.mapDataPointCount) điểm · \(model.mapDataRoadLinkCount) đoạn đường",
                                icon: "signpost.right.and.left.fill",
                                tint: DriveTheme.pink,
                                isOn: $model.showRoadSigns
                            )
                            HStack(spacing: 12) {
                                Image(systemName: "externaldrive.badge.checkmark")
                                    .foregroundStyle(DriveTheme.mint)
                                    .frame(width: 34, height: 34)
                                    .background(DriveTheme.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Dữ liệu bản đồ offline · schema 6")
                                        .font(.subheadline.weight(.bold))
                                    Text("\(model.mapDataRoadLinkCount) đoạn đường · \(model.pendingReviewCount) chờ duyệt · \(model.datasetVersion)")
                                        .font(.caption2)
                                        .foregroundStyle(DriveTheme.ink.opacity(0.52))
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            Button {
                                model.checkForDataUpdate()
                            } label: {
                                SettingsActionRow(
                                    title: model.isCheckingDataUpdate
                                        ? "Đang kiểm tra…"
                                        : "Kiểm tra cập nhật dữ liệu",
                                    icon: "arrow.triangle.2.circlepath",
                                    tint: DriveTheme.mint
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.isDataUpdateConfigured || model.isCheckingDataUpdate)
                            if !model.dataUpdateStatus.isEmpty {
                                Text(model.dataUpdateStatus)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(DriveTheme.ink.opacity(0.58))
                                    .padding(.vertical, 6)
                            } else if !model.isDataUpdateConfigured {
                                Text("Chưa cấu hình VietDriveDataManifestURL; app đang dùng database bundle.")
                                    .font(.caption2)
                                    .foregroundStyle(DriveTheme.ink.opacity(0.48))
                                    .padding(.vertical, 6)
                            }
                            SettingsToggle(
                                title: "Đường đã xác thực",
                                subtitle: "Hiện lớp hình học vượt kiểm tra chất lượng",
                                icon: "point.topleft.down.to.point.bottomright.curvepath",
                                tint: DriveTheme.skyDeep,
                                isOn: $model.showValidatedRoads
                            )
                            Button {
                                let appearance = MapAppearance(rawValue: mapAppearanceRaw) ?? .automatic
                                model.downloadOfflineMapAroundCurrentLocation(
                                    night: appearance.isNight(systemScheme: colorScheme)
                                )
                            } label: {
                                SettingsActionRow(
                                    title: "Tải vùng hiện tại để dùng offline",
                                    icon: "arrow.down.circle.fill",
                                    tint: DriveTheme.skyDeep
                                )
                            }
                            .buttonStyle(.plain)
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
                                .disabled(model.offlineMapPackCount == 0)

                                Button(role: .destructive) {
                                    confirmOfflineMapRemoval = true
                                } label: {
                                    Label("Xóa vùng", systemImage: "trash.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.offlineMapPackCount == 0)
                            }
                            .font(.caption.weight(.bold))
                            if model.offlineMapProgress > 0, model.offlineMapProgress < 1 {
                                ProgressView(value: model.offlineMapProgress)
                                    .tint(DriveTheme.skyDeep)
                            }
                            Text("\(model.offlineMapStatus) · \(model.offlineMapPackCount) vùng đã lưu")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 8)
                        }

                        SettingsCard(title: "CỘNG ĐỒNG", icon: "person.3.fill", tint: DriveTheme.pink) {
                            NavigationLink {
                                CommunityDataHubView()
                            } label: {
                                SettingsActionRow(
                                    title: "Đóng góp dữ liệu bản đồ",
                                    icon: "plus.bubble.fill",
                                    tint: DriveTheme.pink
                                )
                            }
                            .buttonStyle(.plain)
                            HStack(spacing: 7) {
                                Label("\(communityStore.pending.count) chờ duyệt", systemImage: "clock.fill")
                                    .foregroundStyle(DriveTheme.amber)
                                Text("·")
                                Label("\(communityStore.approved.count) đã phát hành", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(DriveTheme.mint)
                                Spacer()
                            }
                            .font(.caption2.weight(.bold))
                            .padding(.bottom, 11)
                            Label(
                                "\(model.mapIssueReportCount) báo cáo sai dữ liệu đang chờ xử lý",
                                systemImage: "exclamationmark.bubble.fill"
                            )
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(DriveTheme.pink)
                            .padding(.bottom, 10)
                        }

                        SettingsCard(title: "CHẨN ĐOÁN", icon: "stethoscope", tint: DriveTheme.amber) {
                            SettingsToggle(
                                title: "Tự động ghi GPS khi dẫn đường",
                                subtitle: "Giữ tối đa 10 hành trình trên thiết bị để tái hiện lỗi",
                                icon: "record.circle",
                                tint: DriveTheme.danger,
                                isOn: $autoRecordDriveTrace
                            )
                            NavigationLink {
                                DriveDiagnosticsView()
                                    .environmentObject(model)
                            } label: {
                                SettingsActionRow(
                                    title: "Chẩn đoán dẫn đường và phát lại GPS",
                                    icon: "stethoscope",
                                    tint: DriveTheme.amber
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        Button(role: .destructive) {
                            model.endUserSession()
                            dismiss()
                            session.logout()
                        } label: {
                            Label("Đăng xuất", systemImage: "rectangle.portrait.and.arrow.right")
                                .font(.headline)
                                .foregroundStyle(DriveTheme.danger)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(.white.opacity(0.82), in: Capsule())
                        }
                        .padding(.top, 4)

                        Text("VietDrive 0.3 · Prototype nội bộ")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DriveTheme.ink.opacity(0.48))
                            .padding(.bottom, 24)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                        .fontWeight(.bold)
                }
            }
            .onDisappear { model.refreshLayerVisibility() }
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

    private var accountCard: some View {
        HStack(spacing: 14) {
            MascotMayView(mood: .neutral, size: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text("Xin chào, \(session.username)!")
                    .font(.system(size: 21, weight: .black, design: .rounded))
                    .foregroundStyle(DriveTheme.ink)
                Text("Tài khoản thử nghiệm VietDrive")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DriveTheme.ink.opacity(0.55))
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(DriveTheme.skyDeep)
        }
        .padding(12)
        .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white, lineWidth: 2))
        .shadow(color: DriveTheme.sky.opacity(0.15), radius: 14, y: 7)
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
                .font(.caption2.weight(.black))
                .tracking(1)
                .foregroundStyle(tint)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .padding(.horizontal, 12)
                .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white, lineWidth: 2))
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
                Text(title).font(.subheadline.weight(.bold)).foregroundStyle(DriveTheme.ink)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(DriveTheme.ink.opacity(0.52))
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: $isOn).labelsHidden().tint(tint)
        }
        .padding(.vertical, 10)
    }
}

private struct SettingsActionRow: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(DriveTheme.ink)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(DriveTheme.ink.opacity(0.28))
        }
        .padding(.vertical, 10)
    }
}
