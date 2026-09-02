import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VietDriveLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        VietDriveLiveActivityWidget()
    }
}

struct VietDriveLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VietDriveActivityAttributes.self) { context in
            VietDriveLockScreenView(state: context.state)
                .activityBackgroundTint(VietDriveActivityPalette.cloud)
                .activitySystemActionForegroundColor(VietDriveActivityPalette.ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MascotActivityView(state: context.state, size: 50)
                        .padding(.leading, 3)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    SpeedLimitBadge(limit: context.state.speedLimitKmh, size: 46)
                        .padding(.trailing, 3)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(statusText(for: context.state))
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(0.7)
                            .foregroundStyle(statusColor(for: context.state))
                            .lineLimit(1)
                        Text(context.state.roadName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.86))
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 11) {
                        CompactSpeedReadout(state: context.state)
                        Rectangle()
                            .fill(.white.opacity(0.13))
                            .frame(width: 1, height: 33)
                        ActivityMessageView(state: context.state, compact: true, style: .dark)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: compactSymbol(for: context.state))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusColor(for: context.state))
            } compactTrailing: {
                HStack(spacing: 2) {
                    Text("\(context.state.speedKmh)")
                        .contentTransition(.numericText())
                    if let limit = context.state.speedLimitKmh {
                        Text("/\(limit)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(context.state.isOverSpeed ? .red : .white)
            } minimal: {
                Image(systemName: compactSymbol(for: context.state))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusColor(for: context.state))
            }
            .keylineTint(statusColor(for: context.state))
        }
    }
}

private struct VietDriveLockScreenView: View {
    let state: VietDriveActivityAttributes.ContentState

    var body: some View {
        ZStack {
            ActivityBackdrop(accent: statusColor(for: state))

            HStack(spacing: 12) {
                MascotActivityView(state: state, size: 72)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor(for: state))
                            .frame(width: 6, height: 6)
                        Text(statusText(for: state))
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(0.65)
                            .foregroundStyle(VietDriveActivityPalette.ink.opacity(0.68))
                            .lineLimit(1)
                    }

                    ActivityMessageView(state: state, compact: false, style: .light)

                    Label(state.roadName, systemImage: "location.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(VietDriveActivityPalette.ink.opacity(0.56))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                ZStack(alignment: .bottomTrailing) {
                    SpeedGauge(state: state, size: 69, style: .light)
                    SpeedLimitBadge(limit: state.speedLimitKmh, size: 35)
                        .offset(x: 3, y: 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}

private struct ActivityBackdrop: View {
    let accent: Color

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    VietDriveActivityPalette.cloud,
                    VietDriveActivityPalette.skySoft,
                    VietDriveActivityPalette.pinkSoft
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(accent.opacity(0.18))
                .frame(width: 125, height: 125)
                .blur(radius: 28)
                .offset(x: -145, y: 34)

            Circle()
                .fill(VietDriveActivityPalette.pink.opacity(0.13))
                .frame(width: 115, height: 115)
                .blur(radius: 20)
                .offset(x: 165, y: -42)

            Capsule()
                .stroke(VietDriveActivityPalette.ink.opacity(0.055), lineWidth: 10)
                .frame(width: 250, height: 88)
                .rotationEffect(.degrees(-12))
                .offset(x: 115, y: 56)
        }
        .clipped()
    }
}

private struct MascotActivityView: View {
    let state: VietDriveActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [statusColor(for: state).opacity(0.24), .clear],
                        center: .center,
                        startRadius: 2,
                        endRadius: size * 0.62
                    )
                )

            FullColorMascotImage(
                assetName: mascotAssetName(for: state),
                padding: size * 0.03
            )
        }
        .frame(width: size, height: size)
        .overlay(
            Circle()
                .stroke(statusColor(for: state).opacity(0.24), lineWidth: 1)
        )
        .widgetAccentable(false)
        .compositingGroup()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mây đang đồng hành")
    }
}

private struct FullColorMascotImage: View {
    let assetName: String
    let padding: CGFloat

    var body: some View {
        Group {
            if #available(iOSApplicationExtension 18.0, *) {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFit()
                    .padding(padding)
            } else {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(padding)
            }
        }
    }
}

private struct ActivityMessageView: View {
    let state: VietDriveActivityAttributes.ContentState
    let compact: Bool
    let style: ActivitySurfaceStyle

    var body: some View {
        HStack(spacing: 7) {
            if let symbol = messageSymbol {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(messageColor)
                    .frame(width: 23, height: 23)
                    .background(messageColor.opacity(style == .light ? 0.18 : 0.13), in: Circle())
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(primaryText)
                    .font((compact ? Font.caption : .subheadline).weight(.semibold))
                    .foregroundStyle(style.primaryText)
                    .lineLimit(compact ? 1 : 2)
                    .minimumScaleFactor(0.78)
                if let distanceText {
                    Text(distanceText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(statusColor(for: state))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryText: String {
        if state.isOverSpeed {
            let excess = max(1, state.speedKmh - (state.speedLimitKmh ?? state.speedKmh))
            return "Vượt \(excess) km/h · Hãy giảm tốc"
        }
        return state.alertText ?? state.instruction ?? (state.speedKmh > 0
            ? "Mây đang đồng hành cùng bạn"
            : "Sẵn sàng cho chuyến đi")
    }

    private var messageSymbol: String? {
        if state.isOverSpeed { return "exclamationmark.triangle.fill" }
        if let alertSymbolName = state.alertSymbolName { return alertSymbolName }
        return state.isNavigating ? "location.north.line.fill" : "road.lanes"
    }

    private var messageColor: Color {
        if state.isOverSpeed { return VietDriveActivityPalette.danger }
        return state.alertText == nil ? statusColor(for: state) : .yellow
    }

    private var distanceText: String? {
        if state.isOverSpeed, let limit = state.speedLimitKmh {
            return "Giới hạn \(limit) km/h"
        }
        if let alertDistance = state.alertDistanceMeters {
            return "Còn \(Self.distance(alertDistance))"
        }
        if let maneuverDistance = state.instructionDistanceMeters,
           state.isNavigating {
            return "Sau \(Self.distance(maneuverDistance))"
        }
        return nil
    }

    private static func distance(_ meters: Int) -> String {
        meters >= 1_000
            ? String(format: "%.1f km", Double(meters) / 1_000)
            : "\(max(0, meters)) m"
    }
}

private struct CompactSpeedReadout: View {
    let state: VietDriveActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 0) {
            Text("\(state.speedKmh)")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("km/h")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(state.isOverSpeed ? .red : .white)
        .frame(width: 53)
    }
}

private struct SpeedGauge: View {
    let state: VietDriveActivityAttributes.ContentState
    let size: CGFloat
    let style: ActivitySurfaceStyle

    var body: some View {
        VStack(spacing: 0) {
            Text("\(state.speedKmh)")
                .font(.system(size: size * 0.42, weight: .black, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("km/h")
                .font(.system(size: size * 0.13, weight: .bold, design: .rounded))
                .foregroundStyle(style.secondaryText)
        }
        .foregroundStyle(state.isOverSpeed ? VietDriveActivityPalette.danger : style.primaryText)
        .frame(width: size, height: size)
        .background(style.gaugeFill, in: Circle())
        .overlay(
            Circle().stroke(
                state.isOverSpeed
                    ? VietDriveActivityPalette.danger
                    : VietDriveActivityPalette.skyDeep.opacity(0.72),
                lineWidth: 2
            )
        )
    }
}

private struct SpeedLimitBadge: View {
    let limit: Int?
    let size: CGFloat

    var body: some View {
        Group {
            if let limit {
                ZStack {
                    Circle().fill(.white)
                    Circle().stroke(.red, lineWidth: max(3, size * 0.09))
                    Text("\(limit)")
                        .font(.system(
                            size: limit >= 100 ? size * 0.31 : size * 0.38,
                            weight: .black,
                            design: .rounded
                        ))
                        .foregroundStyle(.black)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Image(systemName: "road.lanes")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: size, height: size)
                    .background(.white.opacity(0.07), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.11), lineWidth: 1))
            }
        }
        .frame(width: size, height: size)
    }
}

private enum VietDriveActivityPalette {
    static let ink = Color(red: 0.055, green: 0.13, blue: 0.30)
    static let sky = Color(red: 0.30, green: 0.78, blue: 0.98)
    static let skyDeep = Color(red: 0.08, green: 0.48, blue: 0.88)
    static let skySoft = Color(red: 0.78, green: 0.93, blue: 1.00)
    static let cloud = Color(red: 0.94, green: 0.98, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.43, blue: 0.65)
    static let pinkSoft = Color(red: 1.00, green: 0.84, blue: 0.91)
    static let mint = Color(red: 0.24, green: 0.78, blue: 0.66)
    static let amber = Color(red: 1.00, green: 0.67, blue: 0.19)
    static let danger = Color(red: 0.98, green: 0.27, blue: 0.42)
}

private enum ActivitySurfaceStyle: Equatable {
    case light
    case dark

    var primaryText: Color {
        self == .light ? VietDriveActivityPalette.ink : .white
    }

    var secondaryText: Color {
        self == .light
            ? VietDriveActivityPalette.ink.opacity(0.48)
            : .white.opacity(0.47)
    }

    var gaugeFill: Color {
        self == .light ? .white.opacity(0.72) : .white.opacity(0.065)
    }
}

private func mascotAssetName(
    for state: VietDriveActivityAttributes.ContentState
) -> String {
    if state.isOverSpeed { return "MascotMayStop" }

    if state.isNavigating,
       let instruction = state.instruction?.lowercased(),
       state.instructionDistanceMeters.map({ $0 <= 700 }) ?? true,
       ["rẽ", "turn", "quay", "vòng", "exit", "thoát"].contains(where: instruction.contains) {
        return "MascotMayTurn"
    }

    if state.alertText != nil { return "MascotMayStop" }
    return "MascotMayNeutral"
}

private func compactSymbol(
    for state: VietDriveActivityAttributes.ContentState
) -> String {
    if state.isOverSpeed { return "exclamationmark.triangle.fill" }
    if let alertSymbolName = state.alertSymbolName { return alertSymbolName }
    return state.isNavigating ? "location.north.line.fill" : "car.fill"
}

private func statusText(
    for state: VietDriveActivityAttributes.ContentState
) -> String {
    if state.isOverSpeed { return "MÂY NHẮC GIẢM TỐC" }
    if state.alertText != nil { return "MÂY ĐANG CẢNH BÁO" }
    if state.isNavigating { return "MÂY ĐANG CHỈ ĐƯỜNG" }
    return "MÂY · VIETDRIVE"
}

private func statusColor(
    for state: VietDriveActivityAttributes.ContentState
) -> Color {
    if state.isOverSpeed { return VietDriveActivityPalette.danger }
    if state.alertText != nil { return VietDriveActivityPalette.amber }
    if state.isNavigating { return VietDriveActivityPalette.skyDeep }
    return VietDriveActivityPalette.mint
}
