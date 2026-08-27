import SwiftUI

struct OnboardingView: View {
    let onFinished: () -> Void
    @State private var page = 0

    private let pages = [
        OnboardingPage(
            title: "Chào bạn, mình là Mây!",
            subtitle: "Trợ lý hoạt hình mới của VietDrive sẽ đồng hành cùng bạn trên mọi cung đường.",
            mood: .neutral,
            icon: "heart.fill"
        ),
        OnboardingPage(
            title: "Rẽ đúng, đi thật nhẹ nhàng",
            subtitle: "Mây chỉ hướng bằng chuyển động, bản đồ mượt và lời nhắc ngắn gọn, dễ hiểu.",
            mood: .turnLeft,
            icon: "arrow.turn.up.left"
        ),
        OnboardingPage(
            title: "Biển báo luôn trong tầm mắt",
            subtitle: "VietDrive hiển thị dữ liệu đã nhận dạng và nói rõ khi độ phủ còn thiếu.",
            mood: .warning,
            icon: "signpost.right.and.left.fill"
        )
    ]

    var body: some View {
        ZStack {
            CartoonBackground()
            VStack(spacing: 0) {
                HStack {
                    BrandWordmark(compact: true)
                    Spacer()
                    if page < pages.count - 1 {
                        Button("Bỏ qua", action: onFinished)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(DriveTheme.ink.opacity(0.66))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        VStack(spacing: 22) {
                            Spacer(minLength: 20)
                            ZStack {
                                Circle()
                                    .fill(.white.opacity(0.72))
                                    .frame(width: 270, height: 270)
                                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 3))
                                MascotMayView(mood: item.mood, size: 245)
                            }
                            Text(item.title)
                                .font(.system(size: 30, weight: .black, design: .rounded))
                                .foregroundStyle(DriveTheme.ink)
                                .multilineTextAlignment(.center)
                            Text(item.subtitle)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(DriveTheme.ink.opacity(0.64))
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .padding(.horizontal, 26)
                            Label(index == 0 ? "Bản đồ mở, không Google" : "Thiết kế cho hành trình Việt Nam", systemImage: item.icon)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(index.isMultiple(of: 2) ? DriveTheme.pink : DriveTheme.skyDeep)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(.white.opacity(0.72), in: Capsule())
                            Spacer(minLength: 90)
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? DriveTheme.pink : DriveTheme.sky.opacity(0.28))
                            .frame(width: index == page ? 28 : 8, height: 8)
                            .animation(.spring(response: 0.35), value: page)
                    }
                }
                .padding(.bottom, 20)

                Button {
                    if page == pages.count - 1 {
                        onFinished()
                    } else {
                        withAnimation(.snappy) { page += 1 }
                    }
                } label: {
                    HStack {
                        Text(page == pages.count - 1 ? "Bắt đầu cùng Mây" : "Tiếp tục")
                        Image(systemName: "arrow.right")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(colors: [DriveTheme.skyDeep, DriveTheme.pink], startPoint: .leading, endPoint: .trailing),
                        in: Capsule()
                    )
                    .shadow(color: DriveTheme.pink.opacity(0.28), radius: 16, y: 8)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            }
        }
    }
}

private struct OnboardingPage {
    let title: String
    let subtitle: String
    let mood: MascotMood
    let icon: String
}

struct BrandWordmark: View {
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Image("MascotMayNeutral")
                .resizable()
                .scaledToFit()
                .frame(width: compact ? 34 : 46, height: compact ? 34 : 46)
            Text("Viet") + Text("Drive").foregroundColor(DriveTheme.pink)
        }
        .font(.system(size: compact ? 20 : 27, weight: .black, design: .rounded))
        .foregroundStyle(DriveTheme.skyDeep)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("VietDrive")
    }
}
