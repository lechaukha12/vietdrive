import SwiftUI

enum MascotMood: Hashable {
    case neutral
    case ready
    case searching
    case cruising
    case running
    case braking
    case turnLeft
    case turnRight
    case curveLeft
    case curveRight
    case uTurn
    case laneGuide
    case warning
    case speedWarning
    case rerouting
    case celebrate
    case arrived
}

struct MascotMayView: View {
    let mood: MascotMood
    var size: CGFloat = 120
    var isAnimationEnabled = true
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMascotMotion") private var userReduceMotion = false
    @State private var moving = false

    var body: some View {
        ZStack {
            if showsPulse {
                Circle()
                    .stroke(effectColor.opacity(0.42), lineWidth: max(2, size * 0.025))
                    .scaleEffect(moving ? 1.18 : 0.72)
                    .opacity(moving ? 0.03 : 0.65)
            }

            if showsMotionLines {
                VStack(alignment: .leading, spacing: size * 0.045) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(effectColor.opacity(0.52 - Double(index) * 0.10))
                            .frame(
                                width: size * (0.22 - CGFloat(index) * 0.035),
                                height: max(2, size * 0.022)
                            )
                    }
                }
                .offset(x: moving ? -size * 0.48 : -size * 0.34, y: size * 0.08)
                .opacity(moving ? 0.30 : 0.82)
            }

            if mood == .running || mood == .braking {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(DriveTheme.pinkSoft.opacity(0.82 - Double(index) * 0.18))
                        .frame(width: size * (0.12 + CGFloat(index) * 0.045))
                        .blur(radius: size * 0.008)
                        .offset(
                            x: -size * (0.26 + CGFloat(index) * 0.13),
                            y: size * (0.30 - CGFloat(index) * 0.025)
                        )
                        .scaleEffect(moving ? 0.55 : 1.12)
                        .opacity(moving ? 0.28 : 0.76)
                }
            }

            Image(assetName)
                .resizable()
                .scaledToFit()
                .scaleEffect(x: mirrorsAsset ? -1 : 1, y: 1)
                .rotationEffect(.degrees(rotation))
                .offset(x: horizontalOffset, y: verticalOffset)
                .scaleEffect(x: horizontalScale, y: verticalScale)
                .shadow(color: DriveTheme.sky.opacity(0.22), radius: size * 0.08, y: size * 0.04)

            if let badgeIcon {
                Image(systemName: badgeIcon)
                    .font(.system(size: size * 0.13, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.25, height: size * 0.25)
                    .background(effectColor, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .scaleEffect(moving ? 1.08 : 0.92)
                    .offset(x: size * 0.38, y: -size * 0.36)
                    .shadow(color: effectColor.opacity(0.28), radius: size * 0.06, y: 3)
            }

            if mood == .celebrate || mood == .arrived {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: index.isMultiple(of: 2) ? "sparkle" : "star.fill")
                        .font(.system(size: size * (index.isMultiple(of: 2) ? 0.10 : 0.07), weight: .bold))
                        .foregroundStyle(index.isMultiple(of: 2) ? DriveTheme.pink : DriveTheme.amber)
                        .offset(sparkleOffset(index))
                        .rotationEffect(.degrees(moving ? Double(index * 28) : Double(-index * 16)))
                        .scaleEffect(moving ? 1.12 : 0.68)
                }
            }


            if mood == .curveLeft || mood == .curveRight || mood == .uTurn {
                Image(systemName: mood == .uTurn
                      ? "arrow.uturn.backward.circle.fill"
                      : "point.topleft.down.to.point.bottomright.curvepath.fill")
                    .font(.system(size: size * 0.19, weight: .black))
                    .foregroundStyle(.white, DriveTheme.pink)
                    .scaleEffect(x: mood == .curveRight ? -1 : 1, y: 1)
                    .offset(x: size * 0.34, y: size * 0.30)
                    .rotationEffect(.degrees(moving ? 7 : -7))
                    .shadow(color: DriveTheme.pink.opacity(0.25), radius: 5, y: 2)
            }
        }
        .frame(width: size, height: size)
        .id(AnimationState(mood: mood, enabled: !reduceMotion))
        .task(id: AnimationState(mood: mood, enabled: !reduceMotion)) {
            var reset = Transaction(animation: nil)
            reset.disablesAnimations = true
            withTransaction(reset) { moving = false }
            guard !reduceMotion else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            startAnimation()
        }
        .accessibilityHidden(true)
    }

    private var assetName: String {
        switch mood {
        case .running, .cruising: "MascotMayRun"
        case .braking: "MascotMayStop"
        case .turnLeft, .turnRight, .curveLeft, .curveRight, .uTurn, .laneGuide:
            "MascotMayTurn"
        case .celebrate, .arrived: "MascotMayCelebrate"
        default: "MascotMayNeutral"
        }
    }

    private var mirrorsAsset: Bool {
        mood == .turnRight || mood == .curveRight
    }

    private struct AnimationState: Hashable {
        let mood: MascotMood
        let enabled: Bool
    }

    private var reduceMotion: Bool { systemReduceMotion || userReduceMotion || !isAnimationEnabled }

    private var animationDuration: Double {
        return switch mood {
        case .warning, .speedWarning: 0.32
        case .turnLeft, .turnRight, .curveLeft, .curveRight, .uTurn: 0.55
        case .rerouting: 0.62
        case .cruising, .running: 0.36
        case .braking: 0.28
        case .celebrate, .arrived: 0.45
        default: 1.25
        }
    }

    private var verticalOffset: CGFloat {
        guard moving, !reduceMotion else { return 0 }
        return switch mood {
        case .neutral, .ready, .searching: -size * 0.035
        case .cruising, .running: -size * 0.055
        case .celebrate, .arrived: -size * 0.075
        case .braking: size * 0.025
        case .rerouting: -size * 0.02
        default: 0
        }
    }

    private var horizontalOffset: CGFloat {
        guard moving, !reduceMotion else { return 0 }
        return switch mood {
        case .cruising, .running: size * 0.055
        case .braking: -size * 0.035
        case .turnLeft, .curveLeft: -size * 0.025
        case .turnRight, .curveRight: size * 0.025
        case .rerouting: size * 0.018
        default: 0
        }
    }

    private var rotation: Double {
        guard moving, !reduceMotion else { return 0 }
        return switch mood {
        case .turnLeft, .curveLeft: -4
        case .turnRight, .curveRight: 4
        case .uTurn: -7
        case .warning, .speedWarning: -2.5
        case .rerouting: 7
        case .cruising, .running: 3.5
        case .braking: -4
        case .celebrate, .arrived: 4
        default: 1.2
        }
    }

    private var horizontalScale: CGFloat {
        guard moving, !reduceMotion else { return 1 }
        return switch mood {
        case .warning, .speedWarning: 1.035
        case .cruising, .running: 1.05
        case .braking: 1.08
        case .celebrate, .arrived: 1.045
        default: 1
        }
    }

    private var verticalScale: CGFloat {
        guard moving, !reduceMotion else { return 1 }
        return switch mood {
        case .warning, .speedWarning: 0.975
        case .cruising, .running: 0.94
        case .braking: 0.90
        case .celebrate, .arrived: 1.055
        default: 1
        }
    }

    private var showsPulse: Bool {
        switch mood {
        case .searching, .warning, .speedWarning, .rerouting, .arrived: true
        default: false
        }
    }

    private var showsMotionLines: Bool {
        mood == .cruising || mood == .running || mood == .braking || mood == .rerouting
    }

    private var badgeIcon: String? {
        switch mood {
        case .searching: "magnifyingglass"
        case .warning: "exclamationmark"
        case .speedWarning: "gauge.with.dots.needle.67percent"
        case .rerouting: "arrow.triangle.2.circlepath"
        case .turnLeft: "arrow.turn.up.left"
        case .turnRight: "arrow.turn.up.right"
        case .curveLeft: "arrow.up.left"
        case .curveRight: "arrow.up.right"
        case .uTurn: "arrow.uturn.backward"
        case .laneGuide: "arrow.triangle.branch"
        case .ready: "flag.fill"
        case .braking: "stop.fill"
        case .arrived: "checkmark"
        default: nil
        }
    }

    private var effectColor: Color {
        switch mood {
        case .warning, .speedWarning: DriveTheme.danger
        case .rerouting, .searching: DriveTheme.skyDeep
        case .arrived, .celebrate: DriveTheme.mint
        case .turnLeft, .turnRight, .curveLeft, .curveRight, .uTurn, .laneGuide:
            DriveTheme.pink
        default: DriveTheme.sky
        }
    }

    private func sparkleOffset(_ index: Int) -> CGSize {
        let positions: [CGSize] = [
            CGSize(width: -size * 0.39, height: -size * 0.26),
            CGSize(width: size * 0.35, height: -size * 0.28),
            CGSize(width: -size * 0.42, height: size * 0.15),
            CGSize(width: size * 0.40, height: size * 0.18),
            CGSize(width: size * 0.05, height: -size * 0.45)
        ]
        return positions[index % positions.count]
    }

    private func startAnimation() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: animationDuration).repeatForever(autoreverses: true)) {
            moving = true
        }
    }
}
