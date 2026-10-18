import AVFoundation
import Combine
import Speech

/// Audio goes directly to Apple's on-device recognizer. There is no server fallback or audio file.
@MainActor
final class VoiceInputController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var transcript = ""
    @Published var errorMessage: String?
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private var tapInstalled = false
    private var onTranscript: ((String) -> Void)?
    private let permissionBundle: Bundle

    init(permissionBundle: Bundle = .main) { self.permissionBundle = permissionBundle }

    func start(locale: Locale = Locale(identifier: "ru-RU"), onTranscript: @escaping (String) -> Void) async {
        guard !isRecording, !isRequestingPermission else { return }
        errorMessage = nil
        let token = UUID(); generation = token
        isRequestingPermission = true
        defer { if generation == token { isRequestingPermission = false } }
        guard permissionBundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              permissionBundle.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            errorMessage = "Для диктовки запустите установленное приложение STIX Agent с разрешениями микрофона и распознавания речи."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            errorMessage = "Для языка \(locale.identifier) недоступно локальное распознавание. Добавьте язык диктовки в настройках macOS. Облачное распознавание отключено."
            return
        }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == token, !Task.isCancelled else { return }
        guard speech == .authorized else {
            errorMessage = "Разрешите STIX Agent распознавание речи: Системные настройки → Конфиденциальность и безопасность → Распознавание речи."
            return
        }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == token, !Task.isCancelled else { return }
        guard microphone else {
            errorMessage = "Разрешите STIX Agent доступ к микрофону: Системные настройки → Конфиденциальность и безопасность → Микрофон."
            return
        }
        guard recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            errorMessage = "Локальное распознавание сейчас недоступно. Проверьте язык диктовки и повторите попытку."
            return
        }
        self.recognizer = recognizer; self.onTranscript = onTranscript; transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cleanup(); errorMessage = "Микрофон недоступен. Выберите устройство ввода в настройках звука macOS."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapInstalled = true
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Only plain text crosses to the main actor, never audio buffers.
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if let text { self.transcript = text }
                if final { self.stop() }
                else if failed {
                    self.stop()
                    self.errorMessage = "Локальное распознавание завершилось. Проверьте текст, микрофон и язык диктовки перед повторной записью."
                }
            }
        }
        do {
            engine.prepare(); try engine.start(); isRecording = true
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            cleanup(); errorMessage = "Не удалось включить микрофон. Проверьте устройство ввода и разрешение macOS."
        }
    }

    /// Finishes into an editable draft; never sends a chat message.
    func stop() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let completion = onTranscript
        cleanup()
        if !text.isEmpty { completion?(text) }
    }
    func cancel() { cleanup(); transcript = "" }
    private func cleanup() {
        generation = UUID()
        deadline?.cancel(); deadline = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); recognition?.cancel()
        request = nil; recognition = nil; recognizer = nil; onTranscript = nil
        isRecording = false; isRequestingPermission = false
    }

    static func appending(_ transcript: String, to draft: String) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return draft }
        return draft + (draft.isEmpty || draft.last?.isWhitespace == true ? "" : " ") + text
    }
}
