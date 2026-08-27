import SwiftUI

struct LoginView: View {
    let onLogin: (String, String) -> Bool
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var shake = false
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    var body: some View {
        ZStack {
            CartoonBackground()
            ScrollView {
                VStack(spacing: 18) {
                    BrandWordmark()
                        .padding(.top, 22)
                    MascotMayView(mood: errorMessage == nil ? .neutral : .warning, size: 180)
                    VStack(spacing: 6) {
                        Text("Chào mừng bạn trở lại!")
                            .font(.system(size: 27, weight: .black, design: .rounded))
                            .foregroundStyle(DriveTheme.ink)
                        Text("Mây đang đợi để bắt đầu chuyến đi.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DriveTheme.ink.opacity(0.58))
                    }

                    VStack(spacing: 13) {
                        CartoonField(
                            title: "Tên đăng nhập",
                            icon: "person.fill",
                            text: $username,
                            secure: false
                        )
                        .focused($focusedField, equals: .username)
                        CartoonField(
                            title: "Mật khẩu",
                            icon: "lock.fill",
                            text: $password,
                            secure: true
                        )
                        .focused($focusedField, equals: .password)

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(DriveTheme.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button(action: submit) {
                            Text("Đăng nhập")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(
                                    LinearGradient(colors: [DriveTheme.skyDeep, DriveTheme.pink], startPoint: .leading, endPoint: .trailing),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(18)
                    .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white, lineWidth: 2))
                    .shadow(color: DriveTheme.sky.opacity(0.18), radius: 20, y: 10)
                    .offset(x: shake ? -8 : 0)

                    Label("Tài khoản thử nghiệm: admin / admin", systemImage: "key.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(DriveTheme.ink.opacity(0.58))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.60), in: Capsule())
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 30)
            }
        }
        .submitLabel(focusedField == .username ? .next : .go)
        .onSubmit {
            if focusedField == .username { focusedField = .password } else { submit() }
        }
    }

    private func submit() {
        focusedField = nil
        guard onLogin(username.trimmingCharacters(in: .whitespaces), password) else {
            errorMessage = "Tên đăng nhập hoặc mật khẩu chưa đúng."
            withAnimation(.linear(duration: 0.08).repeatCount(5, autoreverses: true)) { shake.toggle() }
            return
        }
        errorMessage = nil
    }
}

private struct CartoonField: View {
    let title: String
    let icon: String
    @Binding var text: String
    let secure: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(DriveTheme.skyDeep)
                .frame(width: 24)
            Group {
                if secure {
                    SecureField(title, text: $text)
                } else {
                    TextField(title, text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(DriveTheme.ink)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(DriveTheme.skySoft.opacity(0.72), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(DriveTheme.sky.opacity(0.34)))
    }
}
