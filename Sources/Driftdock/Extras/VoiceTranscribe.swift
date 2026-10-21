import Foundation
import AppKit
import AVFoundation
import Speech

/// Live dictation that streams into the notch as you speak. Words that are settled show
/// bright; words still being worked out show dimmer. Stopping copies the transcript.
final class VoiceTranscriber: ObservableObject {
    static let shared = VoiceTranscriber()

    @Published private(set) var isRunning = false
    /// Words the recognizer is confident about.
    @Published private(set) var stable = ""
    /// Words still being worked out.
    @Published private(set) var live = ""

    var fullText: String { [stable, live].filter { !$0.isEmpty }.joined(separator: " ") }

    // Created on first use, so launching Driftdock never touches audio hardware.
    private lazy var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private lazy var recognizer = SFSpeechRecognizer()

    private init() {}

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    LiveActivityCenter.shared.flash(symbol: "mic.slash.fill", text: "Allow Speech Recognition for Driftdock", seconds: 3)
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        if granted { self.begin() } else {
                            LiveActivityCenter.shared.flash(symbol: "mic.slash.fill", text: "Allow the microphone for Driftdock", seconds: 3)
                        }
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else {
            LiveActivityCenter.shared.flash(symbol: "mic.slash.fill", text: "Dictation isn't available right now")
            return
        }
        stable = ""
        live = ""

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            LiveActivityCenter.shared.flash(symbol: "mic.slash.fill", text: "Couldn't start the microphone")
            return
        }
        request = req
        isRunning = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    var settled: [String] = []
                    var pending: [String] = []
                    for seg in result.bestTranscription.segments {
                        // Confidence stays 0 until the recognizer commits to a word.
                        if seg.confidence > 0 || result.isFinal { settled.append(seg.substring) } else { pending.append(seg.substring) }
                    }
                    // Keep the formatted (punctuated) text when everything is settled.
                    if pending.isEmpty {
                        self.stable = result.bestTranscription.formattedString
                        self.live = ""
                    } else {
                        self.stable = settled.joined(separator: " ")
                        self.live = pending.joined(separator: " ")
                    }
                }
                if error != nil || (result?.isFinal ?? false), self.isRunning {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil

        let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            ClipboardModel.shared.copy(text)
            LiveActivityCenter.shared.showBanner(.init(symbol: "waveform", tint: .red, title: "Transcript copied",
                                                       subtitle: text, trailing: "doc.on.clipboard"))
        }
    }
}
