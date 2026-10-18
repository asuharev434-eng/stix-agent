import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
    @MainActor @objc func captureSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? (pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String])?.map { URL(fileURLWithPath:$0) } ?? []
        QuickCaptureController.shared.show(text: pasteboard.string(forType:.string) ?? "", urls: Array(urls.prefix(8)))
    }
    func applicationWillTerminate(_ notification: Notification) { LocalServices.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct STIXAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store: AppStore
    init() {
        if LocalFeatureHeadless.handle(CommandLine.arguments) { exit(0) }
        if CommandLine.arguments.contains("--capabilities-json") {
            print(JSONValue.object(NativeCapabilities.status()).encoded)
            exit(0)
        }
        // A separately identified QA bundle can exercise UI with synthetic data,
        // without replacing the user's app or touching its chats and credentials.
        let validationRoot = Bundle.main.object(forInfoDictionaryKey: "STIXValidationRoot") as? String
        _store = StateObject(wrappedValue: AppStore(storage: StateStorage(paths: AppStoragePaths(root: validationRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }))))
    }
    var body: some Scene {
        WindowGroup {
            ChatView().environmentObject(store).preferredColorScheme(store.colorScheme)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.save() }
                .frame(minWidth: 760, minHeight: 570)
                .task {
                    QuickCaptureController.shared.attach(store)
                    if !store.preferences.onboardingComplete { store.showPermissions() }
                    await store.boot()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новый чат") { store.newChat() }.keyboardShortcut("n")
                Button("Новый чат с папкой…") { store.chooseFiles(folderOnly: true, createChat: true) }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Агент") {
                Button("Быстрый запрос · ⌃⌥Пробел") { QuickCaptureController.shared.show() }
                Button("Остановить") { store.stop() }.keyboardShortcut(".")
                Button("Обновить модели") { Task { await store.refreshServices() } }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Доступ к Mac") { store.showPermissions() }
                Button("Открыть локальные данные") { NSWorkspace.shared.open(store.storage.paths.root) }
            }
        }
    }
}
