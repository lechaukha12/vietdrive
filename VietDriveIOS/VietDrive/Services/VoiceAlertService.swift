import AVFoundation
import Foundation

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

final class VoiceAlertService: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
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
        let recordedKey: String?
        let fallbackText: String
        let priority: PromptPriority
        let expiresAt: Date
        let sequence: Int
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let recordedCatalog = RecordedVoiceCatalog()
    private var audioPlayer: AVAudioPlayer?
    private var activePrompt: PendingPrompt?
    private var pendingPrompts: [PendingPrompt] = []
    private var promptSequence = 0
    private var isAudioInterrupted = false
    private var interruptionObserver: NSObjectProtocol?
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
            return "\(recordedCatalog.manifest.voiceName) · MP3 VietMap tạm"
        }
        guard let voice else { return "Giọng tiếng Việt mặc định" }
        switch voice.quality {
        case .premium: return "\(voice.name) · Premium"
        case .enhanced: return "\(voice.name) · Nâng cao"
        default: return "\(voice.name) · Mặc định"
        }
    }

    override init() {
        voice = Self.bestVietnameseVoice()
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
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
        guard isEnabled, alert.distanceMeters >= 80, alert.distanceMeters <= 450 else { return }
        let now = Date()
        guard lastAlertID != alert.id || now.timeIntervalSince(lastSpokenAt) > 90 else { return }

        let distance = naturalDistance(alert.distanceMeters)
        let message: String
        let recordedKey: String?
        let signCode = alert.signCode ?? ""
        let assetName = alert.assetName ?? ""

        if signCode == "IGO:2" || assetName.contains("CameraTraffic") {
            recordedKey = "alert.camera.traffic"
            message = "Phía trước \(distance) có camera phạt nguội đèn đỏ."
        } else if signCode == "IGO:4" || assetName.contains("CameraSection") {
            recordedKey = "alert.camera.section"
            message = "Phía trước \(distance) có camera đo tốc độ theo đoạn."
        } else if signCode == "IGO:11" || assetName.contains("CameraDual") {
            recordedKey = "alert.camera.dual"
            message = "Phía trước \(distance) có camera phạt nguội đèn đỏ và tốc độ."
        } else if signCode == "IGO:10" || signCode == "R420" || assetName.contains("R420") {
            recordedKey = "alert.town.in"
            message = "Phía trước \(distance) bắt đầu khu đông dân cư."
        } else if signCode == "R421" || assetName.contains("R421") {
            recordedKey = "alert.town.out"
            message = "Phía trước \(distance) hết khu đông dân cư."
        } else if signCode == "P125" || assetName.contains("P125") {
            recordedKey = "alert.overtaking.in"
            message = "Phía trước \(distance) đoạn đường cấm vượt."
        } else if signCode == "DP133" || assetName.contains("DP133") {
            recordedKey = "alert.overtaking.out"
            message = "Phía trước \(distance) hết cấm vượt."
        } else if alert.kind == .toll || signCode == "IGO:5" || signCode == "TOLL" || assetName.contains("Toll") {
            recordedKey = "alert.toll"
            message = "Phía trước \(distance) có trạm thu phí."
        } else if signCode == "W240" || assetName.contains("Tunnel") {
            recordedKey = "alert.tunnel"
            message = "Phía trước \(distance) có đường hầm."
        } else if signCode == "W210" || assetName.contains("Railway") {
            recordedKey = "alert.railway"
            message = "Phía trước \(distance) giao nhau với đường sắt."
        } else if signCode == "I433" || assetName.contains("RestArea") {
            recordedKey = "alert.rest_area"
            message = "Phía trước \(distance) có trạm dừng nghỉ."
        } else if assetName.contains("Checkpoint") {
            recordedKey = "alert.checkpoint"
            message = "Phía trước \(distance) có trạm kiểm tra tốc độ."
        } else if alert.speedLimit > 0 {
            recordedKey = speedPromptKey(limit: alert.speedLimit)
            message = alert.kind == .camera
                ? "Phía trước \(distance) có camera tốc độ \(alert.speedLimit) ki lô mét một giờ."
                : "Phía trước \(distance), giới hạn tốc độ \(alert.speedLimit) ki lô mét một giờ."
        } else if alert.kind == .camera {
            recordedKey = "alert.camera"
            message = "Phía trước \(distance) có camera giám sát."
        } else {
            recordedKey = nil
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
        let key = "speed.next.\(limit)"
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
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.delegate = self
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func speedPromptKey(limit: Int) -> String? {
        guard [30, 40, 50, 60, 70, 80, 90, 100, 120].contains(limit) else { return nil }
        return "speed.next.\(limit)"
    }

    static func maneuverPromptKey(step: NavigationStep, stage: Int) -> String? {
        let timing = stage == 1 ? "300" : "now"
        let type = step.type.lowercased()
        if type.contains("roundabout") || type.contains("rotary") {
            guard let exit = step.exitNumber, (1...9).contains(exit) else { return nil }
            return "maneuver.\(timing).roundabout.\(exit)"
        }
        let modifier = step.modifier
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        guard [
            "left", "right", "sharp_left", "sharp_right",
            "slight_left", "slight_right", "straight", "uturn"
        ].contains(modifier) else { return nil }
        return "maneuver.\(timing).\(modifier)"
    }

    @discardableResult
    private func enqueue(
        id: String,
        group: String,
        recordedKey: String?,
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
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        let prompt = pendingPrompts.removeFirst()
        activePrompt = prompt
        try? AVAudioSession.sharedInstance().setActive(true)

        if let key = prompt.recordedKey,
           let url = recordedCatalog?.url(for: key),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.delegate = self
            player.volume = 1
            player.prepareToPlay()
            audioPlayer = player
            if player.play() {
                diagnose("MP3 VietMap · \(key) · \(url.lastPathComponent)")
                return
            }
            audioPlayer = nil
        }

        let utterance = AVSpeechUtterance(string: prompt.fallbackText)
        utterance.voice = voice
        utterance.rate = 0.47
        utterance.pitchMultiplier = 1.03
        utterance.volume = 0.95
        utterance.preUtteranceDelay = 0.08
        utterance.postUtteranceDelay = 0.12
        synthesizer.speak(utterance)
        diagnose("TTS iOS · \(prompt.fallbackText)")
    }

    private func cancelCurrentPlayback(requeue: Bool) {
        if requeue, let activePrompt, activePrompt.expiresAt > Date() {
            pendingPrompts.append(activePrompt)
        }
        activePrompt = nil
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.delegate = self
    }

    private func finishActivePrompt() {
        activePrompt = nil
        audioPlayer = nil
        startNextPromptIfPossible()
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            isAudioInterrupted = true
            cancelCurrentPlayback(requeue: true)
        case .ended:
            isAudioInterrupted = false
            startNextPromptIfPossible()
        @unknown default:
            break
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishActivePrompt()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error { diagnose("Lỗi phát MP3 · \(error.localizedDescription)") }
        finishActivePrompt()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishActivePrompt()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
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
        if alert.kind == .turnRestriction { return true }
        let code = (alert.signCode ?? "").lowercased()
        return code.hasPrefix("p103")
            || code.hasPrefix("p123")
            || code.contains("left_turn")
            || code.contains("right_turn")
            || code.contains("u_turn")
            || code.contains("straight_on")
    }

    private static func bestVietnameseVoice() -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.caseInsensitiveCompare("vi-VN") == .orderedSame }
        return candidates.max { left, right in
            if left.quality.rawValue != right.quality.rawValue {
                return left.quality.rawValue < right.quality.rawValue
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedDescending
        } ?? AVSpeechSynthesisVoice(language: "vi-VN")
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        } catch {
            // Recorded prompts and TTS can still use the system defaults.
        }
    }

    private func diagnose(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onDiagnostic?(message)
        }
    }
}
