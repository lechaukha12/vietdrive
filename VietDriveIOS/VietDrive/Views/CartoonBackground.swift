import SwiftUI

struct CartoonBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [DriveTheme.cloud, DriveTheme.skySoft, DriveTheme.pinkSoft],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(.white.opacity(0.58))
                .frame(width: 250, height: 250)
                .blur(radius: 2)
                .offset(x: -150, y: -310)
            Circle()
                .fill(DriveTheme.pink.opacity(0.16))
                .frame(width: 210, height: 210)
                .offset(x: 155, y: -120)
            Circle()
                .fill(DriveTheme.sky.opacity(0.17))
                .frame(width: 290, height: 290)
                .offset(x: 145, y: 350)
            Path { path in
                path.move(to: CGPoint(x: -20, y: 650))
                path.addCurve(
                    to: CGPoint(x: 460, y: 560),
                    control1: CGPoint(x: 100, y: 500),
                    control2: CGPoint(x: 320, y: 720)
                )
            }
            .stroke(.white.opacity(0.78), style: StrokeStyle(lineWidth: 18, lineCap: .round, dash: [20, 15]))
        }
        .ignoresSafeArea()
    }
}
