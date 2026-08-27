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

final class VoiceAlertService {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let recordedCatalog = RecordedVoiceCatalog()
    private var audioPlayer: AVAudioPlayer?
    private var lastAlertID: Int?
    private var lastSpokenAt = Date.distantPast
    private var announcedOverSpeed = false
    private var navigationStepID: Int?
    private var navigationStage = 0
    private var lastGPSAvailable: Bool?

    var isEnabled = true
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

    init() {
        voice = Self.bestVietnameseVoice()
        configureAudioSession()
    }

    func preview() {
        if !playRecorded("preview", interrupt: true) {
            speak(
                "Xin chào, tôi sẽ nhắc đường và biển báo cho bạn trong suốt hành trình.",
                interrupt: true
            )
        }
    }

    func announce(alert: DriveAlert) {
        guard !Self.isSilentTurnRestriction(alert) else {
            diagnose("Đã chặn voice cấm rẽ · \(alert.signCode ?? alert.kind.rawValue)")
            return
        }
        guard isEnabled, alert.distanceMeters >= 80, alert.distanceMeters <= 450 else { return }
        let now = Date()
        guard lastAlertID != alert.id || now.timeIntervalSince(lastSpokenAt) > 90 else { return }

        lastAlertID = alert.id
        lastSpokenAt = now
        let distance = naturalDistance(alert.distanceMeters)
        let message: String
        let recordedKey: String?
        switch alert.kind {
        case .camera:
            recordedKey = alert.speedLimit > 0
                ? speedPromptKey(limit: alert.speedLimit)
                : "alert.camera"
            message = alert.speedLimit > 0
                ? "Phía trước \(distance) có camera tốc độ \(alert.speedLimit) ki lô mét một giờ."
                : "Phía trước \(distance) có camera giám sát."
        case .speedLimit:
            recordedKey = speedPromptKey(limit: alert.speedLimit)
            message = "Phía trước \(distance), giới hạn tốc độ \(alert.speedLimit) ki lô mét một giờ."
        case .roadSign:
            recordedKey = alert.speedLimit > 0 ? speedPromptKey(limit: alert.speedLimit) : nil
            message = "Phía trước \(distance), \(alert.message.lowercased())."
        case .toll:
            recordedKey = "alert.toll"
            message = "Phía trước \(distance), \(alert.message.lowercased())."
        case .parkingRestriction:
            recordedKey = nil
            message = "Phía trước \(distance), \(alert.message.lowercased())."
        case .turnRestriction:
            return
        default:
            recordedKey = nil
            message = "Phía trước \(distance), \(alert.message.lowercased())."
        }
        if let recordedKey, playRecorded(recordedKey) { return }
        speak(message)
    }

    func updateOverSpeed(_ isOverSpeed: Bool, limit: Int) {
        guard isEnabled else { return }
        if isOverSpeed, !announcedOverSpeed, limit > 0 {
            announcedOverSpeed = true
            // A speed warning must not cut off an active turn instruction.
            if !playRecorded("overspeed") {
                speak(
                    "Bạn đang chạy quá giới hạn \(limit). Vui lòng giảm tốc."
                )
            }
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
        navigationStage = stage
        if let key = Self.maneuverPromptKey(step: step, stage: stage),
           playRecorded(key) {
            return
        }
        let message = distanceMeters <= 80
            ? "Ngay phía trước, \(step.instruction.lowercased())."
            : "Sau \(naturalDistance(Double(distanceMeters))), \(step.instruction.lowercased())."
        speak(message)
    }

    func announceReroute() {
        if !playRecorded("reroute", interrupt: true) {
            speak(
                "Bạn đã đi lệch tuyến. Đang tìm đường mới.",
                interrupt: true
            )
        }
    }

    func announceArrival(modifier: String = "") {
        let normalized = modifier.lowercased()
        let key = normalized.contains("left")
            ? "arrival.left"
            : normalized.contains("right") ? "arrival.right" : "arrival"
        if !playRecorded(key, interrupt: true) {
            speak("Bạn đã đến điểm đến.", interrupt: true)
        }
    }

    func updateGPSAvailability(_ isAvailable: Bool) {
        guard lastGPSAvailable != isAvailable else { return }
        defer { lastGPSAvailable = isAvailable }
        guard lastGPSAvailable != nil else { return }
        let key = isAvailable ? "gps.found" : "gps.lost"
        guard !playRecorded(key, interrupt: false) else { return }
        speak(isAvailable ? "Đã tìm thấy tín hiệu GPS." : "Tín hiệu GPS yếu.")
    }

    func resetNavigation() {
        navigationStepID = nil
        navigationStage = 0
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

    private func playRecorded(_ key: String, interrupt: Bool = false) -> Bool {
        guard isEnabled, let url = recordedCatalog?.url(for: key) else { return false }
        if audioPlayer?.isPlaying == true {
            guard interrupt else { return true }
            audioPlayer?.stop()
        }
        if synthesizer.isSpeaking {
            guard interrupt else { return true }
            synthesizer.stopSpeaking(at: .immediate)
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 1
            player.prepareToPlay()
            audioPlayer = player
            let didPlay = player.play()
            if didPlay { diagnose("MP3 VietMap · \(key) · \(url.lastPathComponent)") }
            return didPlay
        } catch {
            diagnose("Lỗi MP3 \(key) · \(error.localizedDescription)")
            return false
        }
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

    private func speak(_ text: String, interrupt: Bool = false) {
        guard isEnabled else { return }
        if audioPlayer?.isPlaying == true {
            guard interrupt else { return }
            audioPlayer?.stop()
        }
        if synthesizer.isSpeaking {
            guard interrupt else { return }
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = 0.47
        utterance.pitchMultiplier = 1.03
        utterance.volume = 0.95
        utterance.preUtteranceDelay = 0.08
        utterance.postUtteranceDelay = 0.12
        synthesizer.speak(utterance)
        diagnose("TTS iOS · \(text)")
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
