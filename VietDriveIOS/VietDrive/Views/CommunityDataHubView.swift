import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

struct CommunityDataHubView: View {
    @EnvironmentObject private var model: DriveViewModel
    @EnvironmentObject private var session: AppSessionModel
    @ObservedObject private var store = CommunityContributionStore.shared
    @State private var showContributionForm = false
    @State private var showFileImporter = false
    @State private var importPreview: CommunityImportPreview?
    @State private var importError = ""

    var body: some View {
        ZStack {
            CartoonBackground()
            ScrollView {
                VStack(spacing: 15) {
                    hero
                    statusStrip
                    actionPanel
                    moderationPanel
                    auditPanel
                    policyPanel
                }
                .padding(16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Dữ liệu cộng đồng")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showContributionForm) {
            CommunityContributionFormView(
                username: session.username,
                coordinate: model.locationService.location?.coordinate ?? model.snapshot.coordinate
            )
        }
        .sheet(item: $importPreview) { preview in
            CommunityImportPreviewView(preview: preview)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: supportedImportTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("Không thể nhập dữ liệu", isPresented: Binding(
            get: { !importError.isEmpty },
            set: { if !$0 { importError = "" } }
        )) {
            Button("Đã hiểu", role: .cancel) { importError = "" }
        } message: {
            Text(importError)
        }
    }

    private var hero: some View {
        HStack(spacing: 14) {
            MascotMayView(mood: .searching, size: 78)
            VStack(alignment: .leading, spacing: 5) {
                Text("Cùng Mây làm bản đồ tốt hơn!")
                    .font(.system(size: 21, weight: .black, design: .rounded))
                    .foregroundStyle(DriveTheme.ink)
                Text("Mọi đóng góp đều được kiểm tra trước khi xuất hiện trên bản đồ.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DriveTheme.ink.opacity(0.58))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.white.opacity(0.94), DriveTheme.pinkSoft.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26)
        )
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white, lineWidth: 2))
        .shadow(color: DriveTheme.pink.opacity(0.13), radius: 14, y: 7)
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            CommunityStatusPill(
                value: store.pending.count,
                label: "Chờ duyệt",
                icon: "clock.fill",
                tint: DriveTheme.amber
            )
            CommunityStatusPill(
                value: store.approved.count,
                label: "Đã duyệt",
                icon: "checkmark.seal.fill",
                tint: DriveTheme.mint
            )
            CommunityStatusPill(
                value: store.rejected.count,
                label: "Từ chối",
                icon: "xmark.octagon.fill",
                tint: DriveTheme.danger
            )
        }
    }

    private var actionPanel: some View {
        CommunityPanel(title: "ĐÓNG GÓP", icon: "person.3.fill", tint: DriveTheme.skyDeep) {
            Button { showContributionForm = true } label: {
                CommunityActionRow(
                    title: "Gửi một thông tin mới",
                    subtitle: "Dùng vị trí hiện tại, mã biển và bằng chứng",
                    icon: "plus.bubble.fill",
                    tint: DriveTheme.pink
                )
            }
            .buttonStyle(.plain)
            Divider().opacity(0.35)
            Button { showFileImporter = true } label: {
                CommunityActionRow(
                    title: "Nhập tệp dữ liệu",
                    subtitle: "GeoJSON, JSON hoặc CSV · tối đa 5.000 bản ghi",
                    icon: "square.and.arrow.down.fill",
                    tint: DriveTheme.skyDeep
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var moderationPanel: some View {
        if session.username == "admin" {
            CommunityPanel(title: "KIỂM DUYỆN", icon: "checkmark.shield.fill", tint: DriveTheme.mint) {
                NavigationLink {
                    CommunityReviewQueueView(reviewer: session.username)
                } label: {
                    CommunityActionRow(
                        title: "Hàng chờ kiểm duyệt",
                        subtitle: store.pending.isEmpty
                            ? "Không có đề xuất đang chờ"
                            : "\(store.pending.count) đề xuất cần xem xét",
                        icon: "tray.full.fill",
                        tint: DriveTheme.mint
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var auditPanel: some View {
        CommunityPanel(title: "NHẬT KÝ GẦN ĐÂY", icon: "list.bullet.clipboard.fill", tint: DriveTheme.pink) {
            if store.contributions.isEmpty {
                ContentUnavailableView(
                    "Chưa có đóng góp",
                    systemImage: "map.fill",
                    description: Text("Đề xuất mới và kết quả kiểm duyệt sẽ xuất hiện ở đây.")
                )
                .frame(height: 180)
            } else {
                ForEach(Array(store.contributions.sorted { $0.createdAt > $1.createdAt }.prefix(8))) { item in
                    CommunityContributionRow(contribution: item)
                    if item.id != store.contributions.sorted(by: { $0.createdAt > $1.createdAt }).prefix(8).last?.id {
                        Divider().opacity(0.28)
                    }
                }
            }
        }
    }

    private var policyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nguyên tắc phát hành", systemImage: "shield.lefthalf.filled")
                .font(.subheadline.weight(.black))
                .foregroundStyle(DriveTheme.skyDeep)
            Text("Import không đồng nghĩa với xuất bản. VietDrive kiểm tra định dạng, phạm vi Việt Nam, nguồn trùng và bằng chứng; chỉ bản ghi được admin duyệt mới hiện trên bản đồ.")
                .font(.caption.weight(.medium))
                .foregroundStyle(DriveTheme.ink.opacity(0.62))
        }
        .padding(15)
        .background(DriveTheme.skySoft.opacity(0.76), in: RoundedRectangle(cornerRadius: 21))
    }

    private var supportedImportTypes: [UTType] {
        var result: [UTType] = [.json, .commaSeparatedText]
        if let geoJSON = UTType(filenameExtension: "geojson") { result.append(geoJSON) }
        return result
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            importPreview = try store.importPreview(
                data: data,
                fileName: url.lastPathComponent,
                submitter: session.username
            )
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct CommunityContributionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CommunityContributionStore.shared
    let username: String
    @State private var kind: ContributionKind = .roadSign
    @State private var signCode = ""
    @State private var warningText = ""
    @State private var latitudeText: String
    @State private var longitudeText: String
    @State private var conditional = ""
    @State private var sourceReference = ""
    @State private var notes = ""
    @State private var validationMessage = ""

    init(username: String, coordinate: CLLocationCoordinate2D) {
        self.username = username
        _latitudeText = State(initialValue: String(format: "%.7f", coordinate.latitude))
        _longitudeText = State(initialValue: String(format: "%.7f", coordinate.longitude))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CartoonBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        formPanel
                        evidencePanel
                        if !validationMessage.isEmpty {
                            Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(DriveTheme.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(13)
                                .background(DriveTheme.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                        }
                        Button(action: submit) {
                            Label("Gửi vào hàng chờ", systemImage: "paperplane.fill")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(
                                    LinearGradient(
                                        colors: [DriveTheme.skyDeep, DriveTheme.pink],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    in: Capsule()
                                )
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Gửi đóng góp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
            }
            .onChange(of: kind) { _, newValue in
                if warningText.isEmpty { warningText = newValue.defaultMessage }
            }
        }
    }

    private var formPanel: some View {
        CommunityPanel(title: "THÔNG TIN", icon: "mappin.and.ellipse", tint: DriveTheme.skyDeep) {
            Picker("Loại dữ liệu", selection: $kind) {
                ForEach(ContributionKind.allCases) { item in
                    Label(item.title, systemImage: item.iconName).tag(item)
                }
            }
            .font(.subheadline.weight(.bold))
            .padding(.vertical, 9)

            if kind == .roadSign || kind == .speedLimit {
                Divider().opacity(0.3)
                CommunityTextField(title: "Mã biển, ví dụ P130", text: $signCode)
                    .textInputAutocapitalization(.characters)
            }
            Divider().opacity(0.3)
            CommunityTextField(title: "Nội dung cảnh báo", text: $warningText)
            Divider().opacity(0.3)
            HStack(spacing: 10) {
                CommunityTextField(title: "Vĩ độ", text: $latitudeText)
                    .keyboardType(.numbersAndPunctuation)
                CommunityTextField(title: "Kinh độ", text: $longitudeText)
                    .keyboardType(.numbersAndPunctuation)
            }
            Divider().opacity(0.3)
            CommunityTextField(title: "Điều kiện giờ/ngày (nếu có)", text: $conditional)
        }
    }

    private var evidencePanel: some View {
        CommunityPanel(title: "NGUỒN & BẰNG CHỨNG", icon: "camera.fill", tint: DriveTheme.pink) {
            CommunityTextField(title: "Liên kết OSM, ảnh hoặc nguồn công khai", text: $sourceReference)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
            Divider().opacity(0.3)
            CommunityTextField(title: "Mô tả vị trí và bằng chứng quan sát", text: $notes, axis: .vertical)
                .lineLimit(3...6)
            Text("Cần ít nhất một liên kết nguồn hoặc ghi chú bằng chứng đủ rõ.")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DriveTheme.ink.opacity(0.48))
                .padding(.vertical, 8)
        }
    }

    private func submit() {
        guard let latitude = Double(latitudeText.replacingOccurrences(of: ",", with: ".")),
              let longitude = Double(longitudeText.replacingOccurrences(of: ",", with: ".")) else {
            validationMessage = "Tọa độ không hợp lệ"
            return
        }
        let contribution = CommunityContribution(
            kind: kind,
            signCode: signCode.trimmingCharacters(in: .whitespacesAndNewlines),
            warningText: warningText.trimmingCharacters(in: .whitespacesAndNewlines),
            geometry: .point(latitude: latitude, longitude: longitude),
            conditional: conditional.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceReference: sourceReference.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            submitter: username.isEmpty ? "guest" : username
        )
        let result = store.submit(contribution)
        if result.isValid {
            dismiss()
        } else {
            validationMessage = result.errors.joined(separator: "\n")
        }
    }
}

private struct CommunityImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CommunityContributionStore.shared
    let preview: CommunityImportPreview
    @State private var committed = false

    var body: some View {
        NavigationStack {
            ZStack {
                CartoonBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        HStack(spacing: 8) {
                            CommunityStatusPill(value: preview.candidates.count, label: "Hợp lệ", icon: "checkmark.circle.fill", tint: DriveTheme.mint)
                            CommunityStatusPill(value: preview.duplicateCount, label: "Đã có", icon: "doc.on.doc.fill", tint: DriveTheme.amber)
                            CommunityStatusPill(value: preview.issues.count, label: "Có lỗi", icon: "xmark.circle.fill", tint: DriveTheme.danger)
                        }
                        CommunityPanel(title: "XEM TRƯỚC", icon: "doc.text.magnifyingglass", tint: DriveTheme.skyDeep) {
                            ForEach(Array(preview.candidates.prefix(20))) { item in
                                CommunityContributionRow(contribution: item)
                                Divider().opacity(0.25)
                            }
                            if preview.candidates.count > 20 {
                                Text("Và \(preview.candidates.count - 20) bản ghi hợp lệ khác…")
                                    .font(.caption.weight(.bold))
                                    .padding(.vertical, 10)
                            }
                        }
                        if !preview.issues.isEmpty {
                            CommunityPanel(title: "BẢN GHI BỊ LOẠI", icon: "exclamationmark.octagon.fill", tint: DriveTheme.danger) {
                                ForEach(Array(preview.issues.prefix(20))) { issue in
                                    Text("Dòng \(issue.row): \(issue.message)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(DriveTheme.danger)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 7)
                                }
                            }
                        }
                        Button {
                            store.commit(preview)
                            committed = true
                        } label: {
                            Label(
                                committed ? "Đã đưa vào hàng chờ" : "Đưa bản hợp lệ vào hàng chờ",
                                systemImage: committed ? "checkmark.seal.fill" : "tray.and.arrow.down.fill"
                            )
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(committed ? DriveTheme.mint : DriveTheme.skyDeep, in: Capsule())
                        }
                        .disabled(preview.candidates.isEmpty || committed)
                    }
                    .padding(16)
                }
            }
            .navigationTitle(preview.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }.fontWeight(.bold)
                }
            }
        }
    }
}

private struct CommunityReviewQueueView: View {
    @ObservedObject private var store = CommunityContributionStore.shared
    let reviewer: String
    @State private var rejectionTarget: CommunityContribution?

    var body: some View {
        ZStack {
            CartoonBackground()
            if store.pending.isEmpty {
                ContentUnavailableView(
                    "Hàng chờ đã sạch!",
                    systemImage: "checkmark.seal.fill",
                    description: Text("Mây chưa thấy đề xuất nào cần duyệt.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.pending) { item in
                            VStack(alignment: .leading, spacing: 12) {
                                CommunityContributionRow(contribution: item)
                                if !item.notes.isEmpty {
                                    Text(item.notes)
                                        .font(.caption)
                                        .foregroundStyle(DriveTheme.ink.opacity(0.60))
                                }
                                if let anchor = item.anchor {
                                    Text(String(format: "%.6f, %.6f", anchor.latitude, anchor.longitude))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(DriveTheme.ink.opacity(0.48))
                                }
                                HStack(spacing: 10) {
                                    Button {
                                        rejectionTarget = item
                                    } label: {
                                        Label("Từ chối", systemImage: "xmark")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(DriveTheme.danger)
                                    Button {
                                        store.approve(id: item.id, reviewer: reviewer)
                                    } label: {
                                        Label("Duyệt", systemImage: "checkmark")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(DriveTheme.mint)
                                }
                            }
                            .padding(15)
                            .background(.white.opacity(0.90), in: RoundedRectangle(cornerRadius: 22))
                            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white, lineWidth: 2))
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Hàng chờ · \(store.pending.count)")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Từ chối đề xuất này?",
            isPresented: Binding(
                get: { rejectionTarget != nil },
                set: { if !$0 { rejectionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Thiếu bằng chứng", role: .destructive) { reject("Chưa đủ bằng chứng để xác minh") }
            Button("Dữ liệu không chính xác", role: .destructive) { reject("Dữ liệu không chính xác") }
            Button("Trùng dữ liệu", role: .destructive) { reject("Trùng dữ liệu đã có") }
            Button("Hủy", role: .cancel) { rejectionTarget = nil }
        }
    }

    private func reject(_ reason: String) {
        guard let target = rejectionTarget else { return }
        store.reject(id: target.id, reviewer: reviewer, reason: reason)
        rejectionTarget = nil
    }
}

private struct CommunityPanel<Content: View>: View {
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
                .padding(.horizontal, 13)
                .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white, lineWidth: 2))
        }
    }
}

private struct CommunityActionRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.bold)).foregroundStyle(DriveTheme.ink)
                Text(subtitle).font(.caption2).foregroundStyle(DriveTheme.ink.opacity(0.52))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(DriveTheme.ink.opacity(0.28))
        }
        .padding(.vertical, 11)
    }
}

private struct CommunityStatusPill: View {
    let value: Int
    let label: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Label("\(value)", systemImage: icon)
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(DriveTheme.ink.opacity(0.48))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(tint.opacity(0.14)))
    }
}

private struct CommunityContributionRow: View {
    let contribution: CommunityContribution

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: contribution.kind.iconName)
                .foregroundStyle(statusTint)
                .frame(width: 36, height: 36)
                .background(statusTint.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(contribution.warningText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(DriveTheme.ink)
                    .lineLimit(2)
                Text("\(contribution.kind.title) · \(contribution.submitter)")
                    .font(.caption2)
                    .foregroundStyle(DriveTheme.ink.opacity(0.50))
            }
            Spacer(minLength: 5)
            Text(contribution.status.title)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(statusTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(statusTint.opacity(0.10), in: Capsule())
        }
        .padding(.vertical, 9)
    }

    private var statusTint: Color {
        switch contribution.status {
        case .pending: DriveTheme.amber
        case .approved: DriveTheme.mint
        case .rejected: DriveTheme.danger
        }
    }
}

private struct CommunityTextField: View {
    let title: String
    @Binding var text: String
    var axis: Axis = .horizontal

    var body: some View {
        TextField(title, text: $text, axis: axis)
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 12)
    }
}
