import SwiftUI

struct DriveDiagnosticsView: View {
    @EnvironmentObject private var model: DriveViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                diagnosticCard(title: "ĐỊNH VỊ & MAP MATCHING", icon: model.locationFixQuality.symbol) {
                    DiagnosticValueRow(
                        title: model.locationFixQuality.title,
                        value: accuracyText,
                        tint: model.locationFixQuality == .weak ? DriveTheme.amber : DriveTheme.mint
                    )
                    DiagnosticValueRow(
                        title: "Trạng thái bám tuyến",
                        value: model.mapMatchStatus,
                        tint: DriveTheme.skyDeep
                    )
                    DiagnosticValueRow(
                        title: model.snapshot.speedLimitKmh > 0
                            ? "Giới hạn \(model.snapshot.speedLimitKmh) km/h"
                            : "Chưa xác định giới hạn",
                        value: model.speedLimitDiagnosticText,
                        tint: model.snapshot.speedLimitKmh > 0 ? DriveTheme.mint : DriveTheme.amber
                    )
                }

                diagnosticCard(title: "DỊCH VỤ ĐỊNH TUYẾN", icon: "network") {
                    DiagnosticValueRow(
                        title: model.routingHealth.status,
                        value: model.routingHealth.endpoint,
                        tint: model.routingHealth.usedFallback ? DriveTheme.amber : DriveTheme.mint
                    )
                    Text(routeHealthDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                diagnosticCard(title: "VOICE", icon: "waveform.badge.magnifyingglass") {
                    DiagnosticValueRow(
                        title: model.voiceDescription,
                        value: model.voiceDiagnosticText,
                        tint: DriveTheme.pink
                    )
                    Button("Phát prompt kiểm tra") { model.previewVoice() }
                        .buttonStyle(.bordered)
                        .disabled(!model.voiceEnabled)
                }

                diagnosticCard(title: "GHI & PHÁT LẠI GPS", icon: "record.circle") {
                    HStack {
                        Button(model.isTraceRecording ? "Dừng và lưu" : "Bắt đầu ghi") {
                            model.isTraceRecording
                                ? model.finishTraceRecording()
                                : model.startTraceRecording()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(model.isTraceRecording ? DriveTheme.danger : DriveTheme.skyDeep)
                        .disabled(!model.isNavigating && !model.isTraceRecording)
                        if model.isTraceReplayActive {
                            Button("Dừng phát lại") { model.stopTraceReplay() }
                                .buttonStyle(.bordered)
                                .tint(DriveTheme.danger)
                        }
                    }
                    if model.isTraceReplayActive {
                        ProgressView(value: model.traceReplayProgress)
                            .tint(DriveTheme.pink)
                    }
                    if model.savedTraces.isEmpty {
                        Text("Chưa có hành trình. Bản ghi bắt đầu tự động khi dẫn đường GPS thật.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.savedTraces) { trace in
                            traceRow(trace)
                        }
                    }
                    if model.navigationRoute == nil {
                        Text("Chọn một tuyến A → B trước khi phát lại để kiểm tra map matching và reroute.")
                            .font(.caption2)
                            .foregroundStyle(DriveTheme.amber)
                    }
                }

                diagnosticCard(title: "DỮ LIỆU BẢN ĐỒ", icon: "checkmark.seal.fill") {
                    DiagnosticValueRow(
                        title: "Báo cáo chờ kiểm duyệt",
                        value: "\(model.mapIssueReportCount)",
                        tint: DriveTheme.pink
                    )
                    Text("Chạm một biển báo trên bản đồ để xem nguồn, độ tin cậy và gửi báo sai.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(CartoonBackground())
        .navigationTitle("Chẩn đoán")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var accuracyText: String {
        let accuracy = model.locationService.horizontalAccuracy
        return accuracy > 0 ? "Sai số ±\(Int(accuracy)) m" : "Chưa có mẫu GPS"
    }

    private var routeHealthDetail: String {
        var parts: [String] = []
        if model.routingHealth.latencyMilliseconds > 0 {
            parts.append("\(model.routingHealth.latencyMilliseconds) ms")
        }
        if model.routingHealth.usedCache { parts.append("cache offline") }
        if model.routingHealth.usedFallback { parts.append("máy chủ dự phòng") }
        return parts.isEmpty ? "Chưa có yêu cầu trong phiên này" : parts.joined(separator: " · ")
    }

    private func traceRow(_ trace: DriveTrace) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(DriveTheme.skyDeep)
            VStack(alignment: .leading, spacing: 3) {
                Text(trace.routeTitle)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text("\(trace.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(distance(trace.distanceMeters)) · \(Int(trace.durationSeconds)) giây")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.replayTrace(id: trace.id)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.bordered)
            .disabled(model.navigationRoute == nil || model.isTraceReplayActive)
            Button(role: .destructive) {
                model.deleteTrace(id: trace.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.isTraceReplayActive)
        }
        .padding(.vertical, 6)
    }

    private func diagnosticCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.black))
                .foregroundStyle(DriveTheme.ink.opacity(0.62))
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.93), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(DriveTheme.sky.opacity(0.24)))
    }

    private func distance(_ meters: Double) -> String {
        meters >= 1_000
            ? String(format: "%.1f km", meters / 1_000)
            : "\(Int(meters)) m"
    }
}

private struct DiagnosticValueRow: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(tint).frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.bold)).foregroundStyle(DriveTheme.ink)
                Text(value).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
