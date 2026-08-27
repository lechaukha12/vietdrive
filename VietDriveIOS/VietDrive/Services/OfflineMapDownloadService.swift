import CoreLocation
@preconcurrency import MapLibre
import Foundation

@MainActor
final class OfflineMapDownloadService {
    var onUpdate: ((String, Double, Int, Bool) -> Void)? {
        didSet { publishCurrentState() }
    }

    private let storage = MLNOfflineStorage.shared
    private var activePack: MLNOfflinePack?
    private var observers: [NSObjectProtocol] = []
    private var packsObservation: NSKeyValueObservation?
    private var status = "Cache tự động 150 MB đang hoạt động"
    private var progress = 0.0
    private var isDownloading = false

    var packCount: Int { vietDrivePacks.count }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSNotification.Name.MLNOfflinePackProgressChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let pack = notification.object as? MLNOfflinePack else { return }
            Task { @MainActor in self?.handleProgress(for: pack) }
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name.MLNOfflinePackError,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let pack = notification.object as? MLNOfflinePack else { return }
            let error = notification.userInfo?[MLNOfflinePackUserInfoKey.error] as? Error
            Task { @MainActor in
                guard let self, self.isVietDrivePack(pack) else { return }
                self.isDownloading = false
                self.status = "Tải bản đồ bị gián đoạn: \(error?.localizedDescription ?? "lỗi không xác định")"
                self.publishCurrentState()
            }
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name.MLNOfflinePackMaximumMapboxTilesReached,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isDownloading = false
                self?.status = "Đã đạt giới hạn lưu bản đồ offline"
                self?.publishCurrentState()
            }
        })
        packsObservation = storage.observe(\.packs, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.restoreKnownPacks() }
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        packsObservation?.invalidate()
    }

    func downloadArea(around center: CLLocationCoordinate2D, night: Bool) {
        if activePack != nil {
            resumeActiveDownload()
            return
        }
        let latitudePadding = 0.12
        let longitudePadding = 0.12 / max(0.35, cos(center.latitude * .pi / 180))
        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(
                latitude: center.latitude - latitudePadding,
                longitude: center.longitude - longitudePadding
            ),
            ne: CLLocationCoordinate2D(
                latitude: center.latitude + latitudePadding,
                longitude: center.longitude + longitudePadding
            )
        )
        let styleURL = URL(string: night
            ? "https://tiles.openfreemap.org/styles/dark"
            : "https://tiles.openfreemap.org/styles/liberty")
        let region = MLNTilePyramidOfflineRegion(
            styleURL: styleURL,
            bounds: bounds,
            fromZoomLevel: 9,
            toZoomLevel: 15
        )
        let context = "VietDrive|\(center.latitude)|\(center.longitude)|\(night ? "night" : "day")"
            .data(using: .utf8)!
        status = "Đang tạo vùng bản đồ offline…"
        progress = 0
        isDownloading = true
        publishCurrentState()
        storage.addPack(for: region, withContext: context) { [weak self] pack, error in
            Task { @MainActor in self?.handlePackAdded(pack, error: error) }
        }
    }

    func pauseActiveDownload() {
        guard let activePack, activePack.state != .complete else { return }
        activePack.suspend()
        isDownloading = false
        status = "Đã tạm dừng tải bản đồ offline"
        publishCurrentState()
    }

    func resumeActiveDownload() {
        if activePack == nil {
            activePack = vietDrivePacks.first { $0.state != .complete }
        }
        guard let activePack else {
            status = packCount > 0 ? "Các vùng offline đã tải xong" : "Chưa có vùng tải dở"
            publishCurrentState()
            return
        }
        activePack.resume()
        isDownloading = true
        status = "Đang tiếp tục tải bản đồ offline…"
        publishCurrentState()
    }

    func removeAllPacks() {
        let packs = vietDrivePacks
        guard !packs.isEmpty else {
            status = "Không có vùng offline để xóa"
            progress = 0
            publishCurrentState()
            return
        }
        activePack?.suspend()
        activePack = nil
        isDownloading = false
        status = "Đang xóa \(packs.count) vùng offline…"
        publishCurrentState()

        removePacks(packs, firstError: nil)
    }

    private var vietDrivePacks: [MLNOfflinePack] {
        (storage.packs ?? []).filter(isVietDrivePack)
    }

    private func isVietDrivePack(_ pack: MLNOfflinePack) -> Bool {
        String(data: pack.context, encoding: .utf8)?.hasPrefix("VietDrive|") == true
    }

    private func restoreKnownPacks() {
        let packs = vietDrivePacks
        activePack = packs.first { $0.state == .active }
            ?? packs.first { $0.state == .inactive || $0.state == .unknown }
        isDownloading = activePack?.state == .active
        if packs.isEmpty {
            progress = 0
            status = "Cache tự động 150 MB đang hoạt động"
        } else if let activePack {
            activePack.requestProgress()
        } else {
            progress = 1
            status = "Có \(packs.count) vùng bản đồ offline sẵn sàng"
        }
        publishCurrentState()
    }

    private func handlePackAdded(_ pack: MLNOfflinePack?, error: Error?) {
        if let error {
            isDownloading = false
            status = "Không thể tạo vùng offline: \(error.localizedDescription)"
            publishCurrentState()
            return
        }
        guard let pack else {
            isDownloading = false
            status = "Không nhận được gói bản đồ offline"
            publishCurrentState()
            return
        }
        activePack = pack
        status = "Đang tải bản đồ trong bán kính khoảng 13 km…"
        pack.resume()
        publishCurrentState()
    }

    private func removePacks(_ packs: [MLNOfflinePack], firstError: Error?) {
        guard let pack = packs.first else {
            progress = 0
            status = firstError.map {
                "Có vùng chưa xóa được: \($0.localizedDescription)"
            } ?? "Đã xóa toàn bộ bản đồ offline"
            publishCurrentState()
            return
        }
        storage.removePack(pack) { [weak self] error in
            Task { @MainActor in
                self?.removePacks(
                    Array(packs.dropFirst()),
                    firstError: firstError ?? error
                )
            }
        }
    }

    private func handleProgress(for pack: MLNOfflinePack) {
        guard isVietDrivePack(pack) else { return }
        let packProgress = pack.progress
        let expected = packProgress.countOfResourcesExpected
        let fraction = expected > 0
            ? min(1, Double(packProgress.countOfResourcesCompleted) / Double(expected))
            : 0
        let megabytes = Double(packProgress.countOfBytesCompleted) / 1_048_576
        progress = fraction

        switch pack.state {
        case .active:
            activePack = pack
            isDownloading = true
            status = String(format: "Đang tải %.0f%% · %.1f MB", fraction * 100, megabytes)
        case .complete:
            if activePack === pack { activePack = nil }
            isDownloading = false
            progress = 1
            status = String(format: "Đã tải vùng offline · %.1f MB", megabytes)
        case .inactive, .unknown:
            activePack = pack
            isDownloading = false
            status = String(format: "Đã tạm dừng ở %.0f%% · %.1f MB", fraction * 100, megabytes)
        case .invalid:
            if activePack === pack { activePack = nil }
            isDownloading = false
        @unknown default:
            isDownloading = false
        }
        publishCurrentState()
    }

    private func publishCurrentState() {
        onUpdate?(status, progress, packCount, isDownloading)
    }
}
