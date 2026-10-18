import SwiftUI
import AppKit
import PDFKit
import ImageIO

struct DocumentsCard:View{
    @EnvironmentObject var store:AppStore
    @State private var query=""
    @State private var notice=""
    @State private var hits:[DocumentHit]=[]
    @State private var working=false
    @State private var preview:DocumentHit?
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            Label("Локальные документы",systemImage:"doc.text.magnifyingglass").font(.headline)
            Text("PDF — реальные страницы; DOCX и текст — фрагменты. Документы читаются локально, индекс можно восстановить. Поиск автоматически перечитывает изменённые файлы.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.features.documentFolders,id:\.self){folder in
                HStack{Text(folder).font(.caption).textSelection(.enabled);Spacer();Button{store.features.documentFolders.removeAll{$0==folder};store.save();refresh(search:false)}label:{Image(systemName:"xmark.circle")}.help("Отключить папку от поиска")}
            }
            Button("Подключить папку…"){
                let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false
                if panel.runModal() == .OK,let url=panel.url{do{try store.addDocumentFolder(url.path);refresh(search:false)}catch{notice=store.vault.redact(error.localizedDescription)}}
            }
            HStack{TextField("Найти в содержимом документов",text:$query).textFieldStyle(.roundedBorder).onSubmit{refresh(search:true)};Button("Найти"){refresh(search:true)}.disabled(working || query.isEmpty || store.features.documentFolders.isEmpty)}
            Button("Перестроить индекс"){
                guard !working else{return};working=true;let folders=store.features.documentFolders
                Task{defer{working=false};do{notice=try await store.documentIndex.rebuild(folders:folders);hits=[]}catch{notice=store.vault.redact(error.localizedDescription)}}
            }.disabled(working)
            if working{HStack{ProgressView().controlSize(.small);Text("Обновляю индекс и ищу…").font(.caption)}}
            if !notice.isEmpty{Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
            ForEach(hits){hit in
                VStack(alignment:.leading,spacing:6){
                    Button(hit.citation){if hit.page != nil{preview=hit}else{NSWorkspace.shared.open(URL(fileURLWithPath:hit.path))}}.buttonStyle(.link)
                    Text(store.vault.redact(hit.text)).font(.caption).lineLimit(10).textSelection(.enabled)
                    Text(hit.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(10).agentCard(cornerRadius:12)
            }
        }.padding(18).agentCard().sheet(item:$preview){hit in
            VStack{HStack{Text(hit.citation).font(.headline);Spacer();Button("Закрыть"){preview=nil}}.padding();LocalPDFPreview(path:hit.path,page:hit.page ?? 1)}.frame(width:760,height:650)
        }
    }
    private func refresh(search:Bool){
        guard !working else{return};working=true;let folders=store.features.documentFolders,text=query
        Task{defer{working=false};do{notice=try await store.documentIndex.refresh(folders:folders);hits=search ? try await store.documentIndex.search(text,folders:folders) : []}catch{notice=store.vault.redact(error.localizedDescription)}}
    }
}
private struct LocalPDFPreview:NSViewRepresentable{
    let path:String;let page:Int
    func makeNSView(context:Context)->PDFView{let view=PDFView();view.autoScales=true;view.document=PDFDocument(url:URL(fileURLWithPath:path));if let target=view.document?.page(at:max(0,page-1)){view.go(to:target)};return view}
    func updateNSView(_ view:PDFView,context:Context){}
}
struct GalleryCard:View{
    @EnvironmentObject var store:AppStore
    @State private var query=""
    @State private var limit=24
    private var items:[GalleryItem]{store.gallery(query)}
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            Label("Галерея результатов",systemImage:"square.grid.2x2").font(.headline)
            TextField("Поиск по файлам, запросам и чатам",text:$query).textFieldStyle(.roundedBorder)
            if items.isEmpty{Text("Результатов пока нет").foregroundStyle(.secondary)}
            LazyVGrid(columns:[GridItem(.adaptive(minimum:190),spacing:12)],spacing:12){
                ForEach(Array(items.prefix(limit))){item in
                    VStack(alignment:.leading,spacing:8){
                        ResultThumbnail(attachment:item.attachment).frame(height:130)
                        Text(item.attachment.name).font(.caption.weight(.medium)).lineLimit(2)
                        Text(store.vault.redact(item.prompt)).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                        Text(item.createdAt.formatted(date:.abbreviated,time:.shortened)).font(.caption2).foregroundStyle(.secondary)
                        HStack{Button("Открыть"){NSWorkspace.shared.open(URL(fileURLWithPath:item.attachment.path))};Button("В чат"){store.selectChat(item.chatID);store.focusedMessageID=item.messageID}}
                        if let recipe=item.recipe{
                            HStack{Button("Повтор"){store.queueImageRecipe(recipe.id,variant:false,chatID:item.chatID)};Button("Вариант"){store.queueImageRecipe(recipe.id,variant:true,chatID:item.chatID)}}
                            DisclosureGroup("Параметры"){
                                Text("\(recipe.model)\n\(recipe.request.width) × \(recipe.request.height) · шагов \(recipe.request.steps)\nSeed \(recipe.request.seed) · CFG \(recipe.request.cfg)\n\(store.vault.redact(recipe.request.prompt))").font(.caption2).textSelection(.enabled)
                            }.font(.caption)
                        }else if item.attachment.kind=="image"{Text("Для этого файла нет рецепта генерации. Редактирование доступно в исходном чате.").font(.caption2).foregroundStyle(.secondary)}
                    }.padding(12).agentCard(cornerRadius:14)
                }
            }
            if items.count>limit{Button("Показать ещё"){limit+=24}}
            Text("Повтор использует сохранённые модель, seed и промпт; вариант меняет seed. Пиксельное совпадение зависит от ComfyUI и workflow. Файлы остаются по исходным путям.").font(.caption2).foregroundStyle(.secondary)
        }.padding(18).agentCard()
    }
}
private struct ResultThumbnail:View{
    let attachment:Attachment
    @State private var image:CGImage?
    var body:some View{
        Group{if let image{Image(decorative:image,scale:1).resizable().scaledToFit()}else{Image(systemName:attachment.kind=="image" ? "photo" : "doc.text").font(.largeTitle).foregroundStyle(.secondary)}}.frame(maxWidth:.infinity).task(id:attachment.path){
            guard attachment.kind=="image" else{return}
            let path=attachment.path
            image=try? await fileWork{guard let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil) else{return nil as CGImage?};return CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:360] as CFDictionary)}
        }
    }
}
struct ResourcesCard:View{
    @EnvironmentObject var store:AppStore
    @State private var notice=""
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            Label("Ресурсы Mac",systemImage:"gauge.with.dots.needle.33percent").font(.headline)
            Picker("Режим",selection:Binding(get:{store.features.resourceMode},set:{store.features.resourceMode=$0;store.save();store.startNextJob()})){ForEach(ResourceMode.allCases,id:\.self){Text($0.title).tag($0)}}.pickerStyle(.segmented)
            TimelineView(.periodic(from:.now,by:5)){_ in Text(store.resourceReport()).font(.caption).foregroundStyle(.secondary)}
            Text("В экономии фоновые задачи ждут, ручные запросы доступны; резерв ответа ограничен 2048 токенами, стандартная генерация — до 12 шагов. Явно указанные параметры изображения сохраняются. Автоматический режим учитывает экономию питания macOS и нагрев.").font(.caption).foregroundStyle(.secondary)
            Toggle("Быстрый запрос · ⌃⌥Пробел",isOn:Binding(get:{store.features.quickCaptureEnabled},set:{store.features.quickCaptureEnabled=$0;store.save();QuickCaptureController.shared.attach(store)}))
            Button("Открыть быстрый запрос"){QuickCaptureController.shared.show()}
            Button("Освободить модели, загруженные агентом"){
                Task{do{let count=try await ModelResidency.shared.releaseOwned(client:LMStudioClient(endpoint:store.preferences.lmEndpoint));notice="Освобождено экземпляров: \(count). Модели, загруженные другими приложениями, не затронуты."}catch{notice=store.vault.redact(error.localizedDescription)}}
            }.disabled(store.busy)
            if !notice.isEmpty{Text(notice).font(.caption).foregroundStyle(.secondary)}
        }.padding(18).agentCard()
    }
}
