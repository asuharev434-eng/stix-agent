import SwiftUI

struct VoiceInputButton: View {
    @Binding var text: String
    var language: String = "ru-RU"
    @StateObject private var voice = VoiceInputController()
    @State private var startTask: Task<Void, Never>?

    var body: some View {
        Button {
            if voice.isRecording { voice.stop() }
            else {
                startTask = Task { await voice.start(locale: Locale(identifier: language)) { transcript in
                    text = VoiceInputController.appending(transcript, to: text)
                } }
            }
        } label: {
            Label(voice.isRecording ? "Остановить диктовку" : "Диктовка", systemImage: voice.isRecording ? "stop.circle.fill" : "mic")
                .labelStyle(.iconOnly)
                .foregroundStyle(voice.isRecording ? Color.red : Color.secondary)
        }
        .disabled(voice.isRequestingPermission)
        .accessibilityLabel(voice.isRecording ? "Остановить диктовку и добавить текст в черновик" : "Начать локальную диктовку")
        .accessibilityValue(voice.isRecording ? "Микрофон включён" : voice.isRequestingPermission ? "Ожидание разрешения" : "Микрофон выключен")
        .help(voice.isRecording ? "Микрофон включён. Остановите запись и проверьте текст перед отправкой." : "Локальная диктовка — текст появится в черновике")
        .alert("Диктовка", isPresented: Binding(get: { voice.errorMessage != nil }, set: { if !$0 { voice.errorMessage = nil } })) {
            Button("Понятно", role: .cancel) { voice.errorMessage = nil }
        } message: { Text(voice.errorMessage ?? "") }
        .onDisappear { startTask?.cancel(); voice.cancel() }
    }
}
