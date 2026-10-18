import SwiftUI
import AppKit
import Carbon
import ApplicationServices

private func quickCaptureHandler(_ next:EventHandlerCallRef?,_ event:EventRef?,_ context:UnsafeMutableRawPointer?)->OSStatus {
    guard let context else{return noErr}
    let controller=Unmanaged<QuickCaptureController>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated{controller.show()};return noErr
}
private final class QuickPanel:NSPanel { override var canBecomeKey:Bool{true};override var canBecomeMain:Bool{false} }
@MainActor final class QuickCaptureController {
    static let shared=QuickCaptureController()
    weak var store:AppStore?
    private var panel:QuickPanel?
    private var hotkey:EventHotKeyRef?
    private var handler:EventHandlerRef?
    private var pendingCapture:(String,[URL])?
    func attach(_ store:AppStore){
        self.store=store
        if store.features.quickCaptureEnabled{register()}else{unregister()}
        if let pendingCapture{self.pendingCapture=nil;show(text:pendingCapture.0,urls:pendingCapture.1)}
    }
    private func register(){
        guard hotkey==nil else{return}
        var type=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let context=Unmanaged.passUnretained(self).toOpaque()
        let status=InstallEventHandler(GetApplicationEventTarget(),quickCaptureHandler,1,&type,context,&handler)
        guard status==noErr else{store?.featureNotice="Не удалось зарегистрировать горячую клавишу";return}
        let id=EventHotKeyID(signature:OSType(0x53544958),id:1)
        let result=RegisterEventHotKey(UInt32(kVK_Space),UInt32(controlKey|optionKey),id,GetApplicationEventTarget(),0,&hotkey)
        if result != noErr{store?.featureNotice="⌃⌥Пробел занят другим приложением. Быстрый запрос доступен в меню «Агент» и через Службы macOS."}
    }
    func unregister(){if let hotkey{UnregisterEventHotKey(hotkey)};hotkey=nil;if let handler{RemoveEventHandler(handler)};handler=nil}
    func show(text:String?=nil,urls:[URL]=[]){
        let selected=text ?? Self.selectedText()
        guard let store else{pendingCapture=(selected,urls);return}
        let safe=store.vault.redact(selected)
        let window=QuickPanel(contentRect:NSRect(x:0,y:0,width:650,height:290),styleMask:[.titled,.closable,.fullSizeContentView,.nonactivatingPanel],backing:.buffered,defer:false)
        window.title="Быстрый запрос · STIX Agent";window.titlebarAppearsTransparent=true;window.isFloatingPanel=true;window.level = .floating
        window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];window.isReleasedWhenClosed=false
        let content=QuickCaptureView(store:store,text:safe==selected ? selected : "",files:urls,notice:safe != selected ? "Похожее на секрет выделение не добавлено. Используйте защищённый ввод." : nil){[weak self] in self?.panel?.orderOut(nil)}
        window.contentView=NSHostingView(rootView:content);panel?.orderOut(nil);panel=window
        window.center();window.makeKeyAndOrderFront(nil)
    }
    private static func selectedText()->String{
        guard AXIsProcessTrusted() else{return ""}
        let system=AXUIElementCreateSystemWide();var focus:CFTypeRef?
        guard AXUIElementCopyAttributeValue(system,kAXFocusedUIElementAttribute as CFString,&focus) == .success,let focus,CFGetTypeID(focus)==AXUIElementGetTypeID() else{return ""}
        let element=unsafeBitCast(focus,to:AXUIElement.self);var subrole:CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element,kAXSubroleAttribute as CFString,&subrole)
        guard subrole as? String != "AXSecureTextField" else{return ""}
        var value:CFTypeRef?;guard AXUIElementCopyAttributeValue(element,kAXSelectedTextAttribute as CFString,&value) == .success,let text=value as? String,text.count<=16000 else{return ""};return text
    }
}
private struct QuickCaptureView:View{
    @ObservedObject var store:AppStore
    @State var text:String
    @State var files:[URL]
    var notice:String?
    var close:()->Void
    @State private var newChat=true
    @FocusState private var textFocused:Bool
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            TextEditor(text:$text).font(.body).frame(minHeight:95).padding(8).agentCard(cornerRadius:14).accessibilityLabel("Быстрый запрос").focused($textFocused)
            if !files.isEmpty{Text(files.map(\.lastPathComponent).joined(separator:", ")).font(.caption).lineLimit(2)}
            if let notice{Text(notice).font(.caption).foregroundStyle(.orange)}
            HStack{
                Button{let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.allowsMultipleSelection=true;if panel.runModal() == .OK{files=panel.urls}}label:{Label("Файлы",systemImage:"paperclip")}
                Toggle("Новый чат",isOn:$newChat).toggleStyle(.checkbox)
                Spacer();Button("Отмена",action:close).keyboardShortcut(.cancelAction);Button("В чат"){submit(send:false)};Button("Отправить"){submit(send:true)}.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && files.isEmpty)
            }
            Text("⌃⌥Пробел · выделенный текст доступен при разрешённом Универсальном доступе. Файлы из Finder: Службы → Передать в STIX Agent.").font(.caption2).foregroundStyle(.secondary)
        }.padding(20).onAppear{textFocused=true}
    }
    private func submit(send:Bool){
        guard store.vault.redact(text)==text else{store.error="Секреты вводятся через защищённую форму";return}
        if newChat{store.newChat()};store.draft=text;store.addFiles(files);store.save();if send{store.send()};close();NSApp.activate(ignoringOtherApps:true);NSApp.windows.first(where:{!($0 is NSPanel)})?.makeKeyAndOrderFront(nil)
    }
}
