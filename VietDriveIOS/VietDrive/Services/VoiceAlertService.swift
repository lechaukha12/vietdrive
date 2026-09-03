import AVFoundation
import Foundation
import UIKit

struct RecordedVoiceManifest: Decodable {
    let schemaVersion: Int
    let voiceName: String
    let baseDirectory: String
    let prompts: [String: String]
}

struct RecordedVoiceCatalog {
    let manifest: RecordedVoiceManifest
    private let bundle: Bundle

    init?(bundle: Bundle = .main) {
        let manifestURL = bundle.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "VoicePrompts"
        ) ?? bundle.url(forResource: "manifest", withExtension: "json")
        guard let manifestURL,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(RecordedVoiceManifest.self, from: data),
              manifest.schemaVersion == 2 else { return nil }
        self.manifest = manifest
        self.bundle = bundle
    }

    func url(for key: String) -> URL? {
        guard let fileName = manifest.prompts[key] else { return nil }
        let file = fileName as NSString
        let name = file.deletingPathExtension
        let fileExtension = file.pathExtension
        let packName = (manifest.baseDirectory as NSString).lastPathComponent
        let directCandidates = [
            bundle.resourceURL?
                .appendingPathComponent(manifest.baseDirectory, isDirectory: true)
                .appendingPathComponent(fileName),
            bundle.resourceURL?
                .appendingPathComponent(packName, isDirectory: true)
                .appendingPathComponent(fileName)
        ].compactMap { $0 }
        if let existing = directCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            return existing
        }
        return bundle.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: manifest.baseDirectory
        ) ?? bundle.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: packName
        ) ?? bundle.url(forResource: name, withExtension: fileExtension)
    }
}

final class VoiceAlertService: NSObject, AVAudioPlayerDelegate {
    private enum PromptPriority: Int {
        case preview = 10
        case information = 30
        case safetyAlert = 50
        case overSpeed = 70
        case navigation = 90
        case criticalNavigation = 100
    }

    private struct PendingPrompt {
        let id: String
        let group: String
        let recordedKey: String
        let fallbackText: String
        let priority: PromptPriority
        let expiresAt: Date
        let sequence: Int
    }

    private let recordedCatalog = RecordedVoiceCatalog()
    private var audioPlayer: AVAudioPlayer?
    private var activePrompt: PendingPrompt?
    private var pendingPrompts: [PendingPrompt] = []
    private var promptSequence = 0
    private var isAudioInterrupted = false
    private var interruptionObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var isNavigationActive = false
    private var audioRetryWorkItem: DispatchWorkItem?
    private var consecutiveActivationFailures = 0
    private var lastAlertID: Int?
    private var lastSpokenAt = Date.distantPast
    private var announcedOverSpeed = false
    private var navigationStepID: Int?
    private var navigationStage = 0
    private var lastGPSAvailable: Bool?

    var isEnabled = true {
        didSet {
            if !isEnabled { stopAll() }
        }
    }
    var onDiagnostic: ((String) -> Void)?

    var voiceDescription: String {
        if let recordedCatalog {
            return "\(recordedCatalog.manifest.voiceName) · MP3"
        }
        return "Bộ voice Adam chưa sẵn sàng"
    }

    override init() {
        super.init()
        configureAudioSession()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            self?.recoverAfterMediaServicesReset()
        }
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.prepareForBackgroundNavigation(reason: "did_enter_background")
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.prepareForBackgroundNavigation(reason: "will_enter_foreground")
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.pendingPrompts.isEmpty else { return }
            self.consecutiveActivationFailures = 0
            self.startNextPromptIfPossible()
        })
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(mediaServicesResetObserver)
        }
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func setNavigationActive(_ active: Bool) {
        isNavigationActive = active
        if active {
            configureAudioSession()
            diagnose("Audio navigation session sẵn sàng")
        } else {
            diagnose("Audio navigation session đã kết thúc")
            if activePrompt == nil, pendingPrompts.isEmpty {
                deactivateAudioSession()
            }
        }
    }

    func prepareForBackgroundNavigation(reason: String) {
        guard isNavigationActive else { return }
        configureAudioSession()
        diagnose("Audio continuity · \(reason)")
        if activePrompt == nil, !pendingPrompts.isEmpty {
            consecutiveActivationFailures = 0
            startNextPromptIfPossible()
        }
    }

    func preview() {
        enqueue(
            id: "preview",
            group: "preview",
            recordedKey: "preview",
            fallbackText: "Xin chào, tôi sẽ nhắc đường và biển báo cho bạn trong suốt hành trình.",
            priority: .preview,
            lifetime: 15,
            forceInterrupt: true
        )
    }

    func announce(alert: DriveAlert) {
        guard !Self.isSilentTurnRestriction(alert) else {
            diagnose("Đã chặn voice cấm rẽ · \(alert.signCode ?? alert.kind.rawValue)")
            return
        }
        let minimumDistance: Double = alert.isRoadRuleDerived ? 0 : 80
        guard isEnabled,
              alert.distanceMeters >= minimumDistance,
              alert.distanceMeters <= 450 else { return }
        let now = Date()
        guard lastAlertID != alert.id || now.timeIntervalSince(lastSpokenAt) > 90 else { return }

        let distance = naturalDistance(alert.distanceMeters)
        let message: String
        let recordedKey: String

        if let announcement = TrafficSignCatalog.voiceAnnouncement(
            for: alert,
            distanceText: distance
        ) {
            recordedKey = announcement.promptKey
            message = announcement.message
        } else if alert.speedLimit > 0 {
            recordedKey = Self.speedPromptKey(limit: alert.speedLimit)
            message = alert.kind == .camera
                ? "Phía trước \(distance) có camera tốc độ \(alert.speedLimit) ki lô mét một giờ."
                : "Phía trước \(distance), giới hạn tốc độ \(alert.speedLimit) ki lô mét một giờ."
        } else if alert.kind == .camera {
            recordedKey = "alert.camera"
            message = "Phía trước \(distance) có camera giám sát."
        } else if alert.isRoadRuleDerived && alert.distanceMeters < 80 {
            recordedKey = "alert.generic"
            message = "Đoạn đường hiện tại, \(alert.message.lowercased())."
        } else {
            recordedKey = "alert.generic"
            message = "Phía trước \(distance), \(alert.message.lowercased())."
        }
        if enqueue(
            id: "alert-\(alert.id)",
            group: "alert-\(alert.id)",
            recordedKey: recordedKey,
            fallbackText: message,
            priority: .safetyAlert,
            lifetime: 18
        ) {
            lastAlertID = alert.id
            lastSpokenAt = now
        }
    }

    private var lastSpokenNextSpeed: Int?
    private var lastSpokenNextSpeedAt = Date.distantPast

    func announceNextSpeed(limit: Int, distanceMeters: Double) {
        guard isEnabled, distanceMeters >= 120, distanceMeters <= 500 else { return }
        let now = Date()
        guard lastSpokenNextSpeed != limit || now.timeIntervalSince(lastSpokenNextSpeedAt) > 45 else { return }

        let distance = naturalDistance(distanceMeters)
        let key = Self.speedPromptKey(limit: limit)
        let fallback = "Phía trước \(distance), sắp đến đoạn đường giới hạn tốc độ \(limit) ki lô mét một giờ."

        if enqueue(
            id: "next-speed-\(limit)",
            group: "next-speed",
            recordedKey: key,
            fallbackText: fallback,
            priority: .information,
            lifetime: 15
        ) {
            lastSpokenNextSpeed = limit
            lastSpokenNextSpeedAt = now
        }
    }

    func updateOverSpeed(_ isOverSpeed: Bool, limit: Int) {
        guard isEnabled else { return }
        if isOverSpeed, !announcedOverSpeed, limit > 0 {
            announcedOverSpeed = enqueue(
                id: "overspeed-\(limit)",
                group: "overspeed",
                recordedKey: "overspeed",
                fallbackText: "Bạn đang chạy quá giới hạn \(limit). Vui lòng giảm tốc.",
                priority: .overSpeed,
                lifetime: 12
            )
        } else if !isOverSpeed {
            announcedOverSpeed = false
        }
    }

    func updateNavigation(step: NavigationStep?, distanceMeters: Int) {
        guard isEnabled, let step, step.type != "depart" else { return }
        if navigationStepID != step.id {
            navigationStepID = step.id
            navigationStage = 0
        }
        let stage: Int
        if distanceMeters <= 80 {
            stage = 2
        } else if distanceMeters <= 360 {
            stage = 1
        } else {
            return
        }
        guard stage > navigationStage else { return }
        let message = distanceMeters <= 80
            ? "Ngay phía trước, \(step.instruction.lowercased())."
            : "Sau \(naturalDistance(Double(distanceMeters))), \(step.instruction.lowercased())."
        let accepted = enqueue(
            id: "navigation-\(step.id)-\(stage)",
            group: "navigation-step-\(step.id)",
            recordedKey: Self.maneuverPromptKey(step: step, stage: stage),
            fallbackText: message,
            priority: stage == 2 ? .criticalNavigation : .navigation,
            lifetime: stage == 2 ? 9 : 24
        )
        if accepted { navigationStage = stage }
    }

    func announceReroute() {
        enqueue(
            id: "reroute",
            group: "navigation-status",
            recordedKey: "reroute",
            fallbackText: "Bạn đã đi lệch tuyến. Đang tìm đường mới.",
            priority: .criticalNavigation,
            lifetime: 12,
            forceInterrupt: true
        )
    }

    func announceArrival(modifier: String = "") {
        let normalized = modifier.lowercased()
        let key = normalized.contains("left")
            ? "arrival.left"
            : normalized.contains("right") ? "arrival.right" : "arrival"
        enqueue(
            id: "arrival",
            group: "navigation-status",
            recordedKey: key,
            fallbackText: "Bạn đã đến điểm đến.",
            priority: .criticalNavigation,
            lifetime: 15,
            forceInterrupt: true
        )
    }

    func updateGPSAvailability(_ isAvailable: Bool) {
        guard lastGPSAvailable != isAvailable else { return }
        defer { lastGPSAvailable = isAvailable }
        guard lastGPSAvailable != nil else { return }
        let key = isAvailable ? "gps.found" : "gps.lost"
        enqueue(
            id: key,
            group: "gps-status",
            recordedKey: key,
            fallbackText: isAvailable ? "Đã tìm thấy tín hiệu GPS." : "Tín hiệu GPS yếu.",
            priority: .information,
            lifetime: 12
        )
    }

    func resetNavigation() {
        navigationStepID = nil
        navigationStage = 0
        pendingPrompts.removeAll { $0.group.hasPrefix("navigation-") }
    }

    func stopAll() {
        audioRetryWorkItem?.cancel()
        audioRetryWorkItem = nil
        consecutiveActivationFailures = 0
        pendingPrompts.removeAll()
        activePrompt = nil
        lastAlertID = nil
        lastSpokenAt = .distantPast
        announcedOverSpeed = false
        navigationStepID = nil
        navigationStage = 0
        lastGPSAvailable = nil
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        deactivateAudioSession()
    }

    static func speedPromptKey(limit: Int) -> String {
        [30, 40, 50, 60, 70, 80, 90, 100, 120].contains(limit)
            ? "speed.next.\(limit)"
            : "speed.generic"
    }

    static func maneuverPromptKey(step: NavigationStep, stage: Int) -> String {
        let timing = stage == 1 ? "300" : "now"
        let type = step.type.lowercased()
        if type.contains("roundabout") || type.contains("rotary") {
            guard let exit = step.exitNumber, (1...9).contains(exit) else {
                return "maneuver.generic"
            }
            return "maneuver.\(timing).roundabout.\(exit)"
        }
        let modifier = step.modifier
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        guard [
            "left", "right", "sharp_left", "sharp_right",
            "slight_left", "slight_right", "straight", "uturn"
        ].contains(modifier) else { return "maneuver.generic" }
        return "maneuver.\(timing).\(modifier)"
    }

    @discardableResult
    private func enqueue(
        id: String,
        group: String,
        recordedKey: String,
        fallbackText: String,
        priority: PromptPriority,
        lifetime: TimeInterval,
        forceInterrupt: Bool = false
    ) -> Bool {
        guard isEnabled else { return false }
        promptSequence += 1
        let prompt = PendingPrompt(
            id: id,
            group: group,
            recordedKey: recordedKey,
            fallbackText: fallbackText,
            priority: priority,
            expiresAt: Date().addingTimeInterval(lifetime),
            sequence: promptSequence
        )

        pendingPrompts.removeAll { $0.id == id || $0.group == group }
        if forceInterrupt || (activePrompt.map { priority.rawValue > $0.priority.rawValue } ?? false) {
            cancelCurrentPlayback(requeue: false)
        }
        pendingPrompts.append(prompt)
        pendingPrompts.sort {
            if $0.priority.rawValue != $1.priority.rawValue {
                return $0.priority.rawValue > $1.priority.rawValue
            }
            return $0.sequence < $1.sequence
        }
        if pendingPrompts.count > 10 {
            pendingPrompts.removeLast(pendingPrompts.count - 10)
        }
        startNextPromptIfPossible()
        return activePrompt?.id == id || pendingPrompts.contains { $0.id == id }
    }

    private func startNextPromptIfPossible() {
        guard isEnabled, !isAudioInterrupted, activePrompt == nil else { return }
        let now = Date()
        pendingPrompts.removeAll { $0.expiresAt <= now }
        guard !pendingPrompts.isEmpty else {
            deactivateAudioSession()
            return
        }
        let prompt = pendingPrompts.removeFirst()
        activePrompt = prompt
        guard activateAudioSession() else {
            activePrompt = nil
            if prompt.expiresAt > Date() {
                pendingPrompts.insert(prompt, at: 0)
                scheduleAudioRetry(for: prompt)
            }
            return
        }
        audioRetryWorkItem?.cancel()
        audioRetryWorkItem = nil
        consecutiveActivationFailures = 0

        if let url = recordedCatalog?.url(for: prompt.recordedKey),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.delegate = self
            player.volume = 1
            player.prepareToPlay()
            audioPlayer = player
            if player.play() {
                diagnose("MP3 \(recordedCatalog?.manifest.voiceName ?? "VietDrive") · \(prompt.recordedKey) · \(url.lastPathComponent)")
                return
            }
            audioPlayer = nil
        }

        diagnose("Thiếu MP3 Adam · \(prompt.recordedKey) · \(prompt.fallbackText)")
        finishActivePrompt()
    }

    private func cancelCurrentPlayback(requeue: Bool) {
        if requeue, let activePrompt, activePrompt.expiresAt > Date() {
            pendingPrompts.append(activePrompt)
        }
        activePrompt = nil
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private func finishActivePrompt() {
        consecutiveActivationFailures = 0
        activePrompt = nil
        audioPlayer = nil
        startNextPromptIfPossible()
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            audioRetryWorkItem?.cancel()
            audioRetryWorkItem = nil
            isAudioInterrupted = true
            cancelCurrentPlayback(requeue: true)
            diagnose("Audio interruption bắt đầu")
        case .ended:
            isAudioInterrupted = false
            consecutiveActivationFailures = 0
            configureAudioSession()
            diagnose("Audio interruption kết thúc")
            startNextPromptIfPossible()
        @unknown default:
            break
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        diagnose(flag ? "MP3 đã phát xong" : "MP3 kết thúc không thành công")
        finishActivePrompt()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error { diagnose("Lỗi phát MP3 · \(error.localizedDescription)") }
        finishActivePrompt()
    }

    private func naturalDistance(_ meters: Double) -> String {
        if meters >= 1_000 {
            let kilometers = (meters / 1_000 * 10).rounded() / 10
            return kilometers == kilometers.rounded()
                ? "\(Int(kilometers)) ki lô mét"
                : String(format: "%.1f ki lô mét", kilometers)
        }
        let rounded = max(50, Int((meters / 50).rounded()) * 50)
        return "khoảng \(rounded) mét"
    }

    static func isSilentTurnRestriction(_ alert: DriveAlert) -> Bool {
        // Relation-derived restrictions do not encode the driver's intended
        // branch in free-drive mode. Physical sign nodes (P103/P123/P124) do,
        // and should be announced like other audited road signs.
        alert.kind == .turnRestriction
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
        } catch {
            diagnose("Lỗi cấu hình audio · \(error.localizedDescription)")
        }
    }

    private func activateAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            try session.setActive(true)
            return true
        } catch {
            diagnose("Lỗi kích hoạt audio · \(error.localizedDescription)")
            return false
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            diagnose("Lỗi đóng audio · \(error.localizedDescription)")
        }
    }

    private func recoverAfterMediaServicesReset() {
        audioRetryWorkItem?.cancel()
        audioRetryWorkItem = nil
        consecutiveActivationFailures = 0
        cancelCurrentPlayback(requeue: true)
        isAudioInterrupted = false
        configureAudioSession()
        diagnose("Audio services đã được khôi phục")
        startNextPromptIfPossible()
    }

    private func scheduleAudioRetry(for prompt: PendingPrompt) {
        guard audioRetryWorkItem == nil else { return }
        consecutiveActivationFailures += 1
        guard consecutiveActivationFailures <= 3 else {
            diagnose("Audio chưa thể kích hoạt sau 3 lần · giữ prompt chờ route/lifecycle mới")
            return
        }
        let delay = 0.6 * pow(2, Double(consecutiveActivationFailures - 1))
        diagnose("Audio retry \(consecutiveActivationFailures)/3 sau \(String(format: "%.1f", delay))s")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.audioRetryWorkItem = nil
            guard prompt.expiresAt > Date(),
                  self.pendingPrompts.contains(where: { $0.id == prompt.id }) else { return }
            self.startNextPromptIfPossible()
        }
        audioRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func diagnose(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onDiagnostic?(message)
        }
    }
}
