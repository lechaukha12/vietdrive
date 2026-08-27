import SwiftUI

/// Fixed 480x272 companion display frame. It is rendered to JPEG and chunked over BLE.
struct DeviceProjectionView: View {
    let snapshot: DriveSnapshot

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [DriveTheme.ink, Color(red: 0.03, green: 0.13, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.10), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: min(1, CGFloat(snapshot.speedKmh) / 140))
                        .stroke(
                            snapshot.isOverSpeed ? DriveTheme.danger : DriveTheme.cyan,
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: -4) {
                        Text("\(snapshot.speedKmh)")
                            .font(.system(size: 60, weight: .black, design: .rounded))
                        Text("KM/H")
                            .font(.caption.weight(.black))
                            .tracking(2)
                            .foregroundStyle(DriveTheme.textMuted)
                    }
                }
                .frame(width: 166, height: 166)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: 34, weight: .black))
                            .foregroundStyle(DriveTheme.mint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.nextManeuver)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .lineLimit(1)
                            Text(snapshot.maneuverDistanceMeters > 0 ? "Sau \(snapshot.maneuverDistanceMeters) mét" : snapshot.roadName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DriveTheme.textMuted)
                        }
                    }

                    Divider().overlay(Color.white.opacity(0.12))

                    if let alert = snapshot.primaryAlert {
                        HStack(spacing: 10) {
                            Image(systemName: alert.kind.iconName)
                                .foregroundStyle(DriveTheme.alertColor(alert.kind))
                            Text(alert.message)
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(alert.distanceMeters))m")
                                .font(.subheadline.weight(.black))
                        }
                    } else {
                        Label("Hành trình an toàn", systemImage: "checkmark.shield.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DriveTheme.mint)
                    }
                }

                SpeedLimitSign(limit: snapshot.speedLimitKmh)
            }
            .padding(24)

            VStack {
                HStack {
                    Text("VIETDRIVE")
                        .font(.caption2.weight(.black))
                        .tracking(2)
                        .foregroundStyle(DriveTheme.cyan)
                    Spacer()
                    Text(snapshot.province)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DriveTheme.textMuted)
                }
                Spacer()
            }
            .padding(14)
        }
        .frame(width: 480, height: 272)
        .clipped()
    }
}

struct DevicePreviewSheet: View {
    @EnvironmentObject private var model: DriveViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GeometryReader { geometry in
                        let scale = min(1, geometry.size.width / 480)
                        DeviceProjectionView(snapshot: model.snapshot)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12)))
                            .scaleEffect(scale, anchor: .topLeading)
                    }
                    .frame(height: 220)

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Màn hình phụ ESP32", systemImage: "rectangle.connected.to.line.below")
                            .font(.headline)
                        Text("VietDrive gửi telemetry JSON và ảnh HUD JPEG 480×272 qua BLE. ESP32 chỉ cần ghép các chunk rồi giải mã JPEG để hiển thị.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("TRẠNG THÁI")
                                    .font(.caption2.weight(.black))
                                    .foregroundStyle(.secondary)
                                Text(model.bluetooth.state.label)
                                    .font(.subheadline.weight(.bold))
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { model.bluetooth.isEnabled },
                                set: { _ in model.toggleBluetooth() }
                            ))
                            .labelsHidden()
                            .tint(DriveTheme.cyan)
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding()
            }
            .background(DriveTheme.ink.ignoresSafeArea())
            .navigationTitle("VietDrive Box")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
