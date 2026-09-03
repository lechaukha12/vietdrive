import SwiftUI

struct DrivingDemoView: View {
    @EnvironmentObject private var model: DriveViewModel
    @Environment(\.dismiss) private var dismiss
    var onChooseRoute: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 14) {
                        Image(systemName: "car.side.hill.up.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(DriveTheme.skyDeep)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lái thử tại chỗ")
                                .font(.title3.bold())
                            Text("Chạy ngay tuyến có sẵn, không cần tìm đường hay bản ghi GPS.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        if model.startFixedRouteDemo() { dismiss() }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle.fill").font(.system(size: 36))
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Sài Gòn → Phan Thiết").font(.headline)
                                Text("168 km · Có sẵn trong app · Không cần mạng")
                                    .font(.caption)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14).frame(maxWidth: .infinity)
                        .foregroundStyle(.white)
                        .background(DriveTheme.skyDeep, in: RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Bắt đầu chạy thử Sài Gòn đến Phan Thiết, không cần mạng")
                    if let error = model.routeErrorMessage {
                        Text(error).font(.caption).foregroundStyle(DriveTheme.amber)
                    }
                    if let playback = model.routeDemo {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ĐẾN NHANH MỘT ĐOẠN TUYẾN")
                                .font(.caption.bold()).foregroundStyle(DriveTheme.skyDeep)
                            HStack {
                                ForEach([0, 25, 50, 75, 95], id: \.self) { percent in
                                    Button("\(percent)%") { model.seekRouteDemo(to: Double(percent) / 100) }
                                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                                }
                            }
                            Text("Đã đi \(Int(playback.distanceMeters / 1_000)) / \(Int(playback.totalDistanceMeters / 1_000)) km")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("HOẶC DÙNG TUYẾN ĐÃ CHỌN")
                            .font(.caption.bold()).foregroundStyle(DriveTheme.skyDeep)
                        if model.isPlanningRoute {
                            ProgressView("Đang tìm tuyến…")
                        } else if model.navigationRoute != nil {
                            Text(model.selectedRouteTitle).font(.subheadline.weight(.semibold))
                        } else {
                            Text("Chưa chọn tuyến đường")
                                .font(.subheadline.weight(.semibold))
                            Text("Chọn điểm bắt đầu và điểm đến để tạo tuyến trước.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let onChooseRoute {
                            Button(model.navigationRoute == nil ? "Chọn tuyến đường" : "Chọn tuyến khác",
                                   systemImage: "map", action: onChooseRoute)
                                .buttonStyle(.bordered)
                        }
                    }
                    VStack(spacing: 10) {
                        HStack {
                            Text("Tốc độ thử").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(model.demoSpeedKmh) km/h")
                                .font(.title3.bold()).monospacedDigit().foregroundStyle(DriveTheme.skyDeep)
                        }
                        Slider(value: Binding(get: { Double(model.demoSpeedKmh) },
                                              set: { model.updateDemoSpeed(Int($0.rounded())) }),
                               in: 10...120, step: 10)
                            .tint(DriveTheme.skyDeep)
                            .accessibilityLabel("Tốc độ chạy thử")
                            .accessibilityValue("\(model.demoSpeedKmh) kilomet mỗi giờ")
                    }
                    if model.isRouteDemoActive, model.routeDemo?.isFinished != true {
                        HStack(spacing: 12) {
                            Button(model.routeDemo?.isPaused == true ? "Tiếp tục" : "Tạm dừng",
                                   systemImage: model.routeDemo?.isPaused == true ? "play.fill" : "pause.fill") {
                                if model.routeDemo?.isPaused == true { model.resumeRouteDemo() }
                                else { model.pauseRouteDemo() }
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Thoát DEMO", role: .cancel) { model.stopRouteDemo(); dismiss() }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        Button {
                            if model.startRouteDemo() { dismiss() }
                        } label: {
                            Label(model.routeDemo?.isFinished == true ? "Chạy lại từ đầu" : "Bắt đầu chạy thử",
                                  systemImage: "play.fill")
                                .frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.navigationRoute == nil || model.isPlanningRoute || model.isTraceReplayActive)
                        if model.isRouteDemoActive {
                            Button("Thoát DEMO") { model.stopRouteDemo(); dismiss() }
                        }
                    }
                    if model.isTraceReplayActive {
                        Text("Dừng phát lại GPS trước khi chạy thử tuyến.")
                            .font(.caption).foregroundStyle(DriveTheme.amber)
                    }
                    Label("Chỉ dùng khi đang dừng xe. DEMO tạm ngừng GPS thật, chỉ hiển thị trên iPhone và tự tạm dừng khi app ra nền. Không lưu thành hành trình thật.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Tuyến thử: OSRM · © OpenStreetMap contributors (ODbL)",
                         destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.caption2)
                }
                .padding(20)
            }
            .background(DriveTheme.cloud)
            .navigationTitle("Chạy thử · DEMO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } }
            }
        }
        .tint(DriveTheme.skyDeep)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// Always accessible on both the map and the driving cockpit while a demo is active.
struct DrivingDemoStatusBar: View {
    @EnvironmentObject private var model: DriveViewModel
    let onOpenControls: () -> Void

    var body: some View {
        if let playback = model.routeDemo {
            HStack(spacing: 8) {
                Button(action: onOpenControls) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playback.isFinished ? "DEMO · Hoàn tất" : playback.isPaused ? "DEMO · Tạm dừng" : "DEMO · Đang chạy")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                        ProgressView(value: playback.progress)
                            .tint(DriveTheme.skyDeep)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Điều chỉnh chạy thử, \(Int(playback.progress * 100)) phần trăm")
                Menu {
                    ForEach([10, 20, 30, 40, 50, 60, 80, 100, 120], id: \.self) { speed in
                        Button("\(speed) km/h") { model.updateDemoSpeed(speed) }
                    }
                } label: {
                    Text("\(model.demoSpeedKmh) km/h")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit().frame(minHeight: 44)
                }
                .accessibilityLabel("Chỉnh tốc độ chạy thử")
                Button {
                    if playback.isFinished { model.startRouteDemo() }
                    else if playback.isPaused { model.resumeRouteDemo() }
                    else { model.pauseRouteDemo() }
                } label: {
                    Image(systemName: playback.isFinished ? "arrow.counterclockwise" : playback.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel(playback.isFinished ? "Chạy lại" : playback.isPaused ? "Tiếp tục chạy thử" : "Tạm dừng chạy thử")
                Button { model.stopRouteDemo() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Thoát DEMO, trở về GPS thật")
            }
            .foregroundStyle(DriveTheme.skyDeep)
            .padding(.horizontal, 14)
            .background(DriveTheme.skySoft)
        }
    }
}
