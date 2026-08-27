import SwiftUI

enum MapAppearance: String, CaseIterable, Identifiable {
    case automatic
    case day
    case night

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Tự động"
        case .day: "Ban ngày"
        case .night: "Ban đêm"
        }
    }

    func isNight(systemScheme: ColorScheme) -> Bool {
        switch self {
        case .automatic:
            let hour = Calendar.current.component(.hour, from: Date())
            return systemScheme == .dark || hour >= 18 || hour < 6
        case .day: return false
        case .night: return true
        }
    }
}

enum DriveTheme {
    static let ink = Color(red: 0.055, green: 0.13, blue: 0.30)
    static let panel = Color.white
    static let sky = Color(red: 0.30, green: 0.78, blue: 0.98)
    static let skyDeep = Color(red: 0.08, green: 0.48, blue: 0.88)
    static let skySoft = Color(red: 0.78, green: 0.93, blue: 1.00)
    static let cloud = Color(red: 0.94, green: 0.98, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.43, blue: 0.65)
    static let pinkSoft = Color(red: 1.00, green: 0.84, blue: 0.91)
    static let cyan = skyDeep
    static let mint = Color(red: 0.24, green: 0.78, blue: 0.66)
    static let amber = Color(red: 1.00, green: 0.67, blue: 0.19)
    static let danger = Color(red: 0.98, green: 0.27, blue: 0.42)
    static let textMuted = ink.opacity(0.55)

    static func alertColor(_ kind: AlertKind) -> Color {
        switch kind {
        case .camera: danger
        case .speedLimit: amber
        case .toll: mint
        case .hazard: Color.orange
        case .roadSign: amber
        case .turnRestriction: danger
        case .parkingRestriction: pink
        }
    }
}

struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 24
    var strokeOpacity: Double = 0.14

    func body(content: Content) -> some View {
        content
            .background(Color.white.opacity(0.90), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(DriveTheme.sky.opacity(max(0.18, strokeOpacity)), lineWidth: 1.5)
            }
            .shadow(color: DriveTheme.skyDeep.opacity(0.14), radius: 18, y: 8)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 24, strokeOpacity: Double = 0.14) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, strokeOpacity: strokeOpacity))
    }
}
