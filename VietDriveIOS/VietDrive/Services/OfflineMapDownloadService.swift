import CoreLocation
@preconcurrency import MapLibre
import Foundation

final class OfflineMapDownloadService: @unchecked Sendable {
    var onUpdate: ((String, Double, Int) -> Void)?
    private var activePack: MLNOfflinePack?
    private var progressTimer: Timer?

    var packCount: Int { MLNOfflineStorage.shared.packs?.count ?? 0 }

    func downloadArea(around center: CLLocationCoordinate2D, night: Bool) {
        guard activePack == nil else { return }
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
        onUpdate?("Đang tạo vùng bản đồ offline…", 0, packCount)
        MLNOfflineStorage.shared.addPack(for: region, withContext: context) { [weak self] pack, error in
            guard let self else { return }
            if let error {
                self.onUpdate?("Không thể tạo vùng offline: \(error.localizedDescription)", 0, self.packCount)
                return
            }
            guard let pack else {
                self.onUpdate?("Không nhận được gói bản đồ offline", 0, self.packCount)
                return
            }
            self.activePack = pack
            pack.resume()
            self.onUpdate?("Đang tải bản đồ trong bán kính khoảng 13 km…", 0, self.packCount)
            self.startPolling(pack)
        }
    }

    private func startPolling(_ pack: MLNOfflinePack) {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let pack = self.activePack else { return }
            pack.requestProgress()
            let progress = pack.progress
            let expected = progress.countOfResourcesExpected
            let fraction = expected > 0
                ? min(1, Double(progress.countOfResourcesCompleted) / Double(expected))
                : 0
            let megabytes = Double(progress.countOfBytesCompleted) / 1_048_576
            if pack.state == .complete || fraction >= 0.999 {
                self.onUpdate?(
                    String(format: "Đã tải vùng offline · %.1f MB", megabytes),
                    1,
                    self.packCount
                )
                self.progressTimer?.invalidate()
                self.progressTimer = nil
                self.activePack = nil
            } else {
                self.onUpdate?(
                    String(format: "Đang tải %.0f%% · %.1f MB", fraction * 100, megabytes),
                    fraction,
                    self.packCount
                )
            }
        }
    }
}
