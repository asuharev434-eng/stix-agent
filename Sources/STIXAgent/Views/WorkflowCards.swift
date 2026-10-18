import SwiftUI
import AppKit

struct WorkflowsCard:View{
    @EnvironmentObject var store:AppStore
    let chatID:UUID
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            Label("Сценарии с формами",systemImage:"slider.horizontal.3").font(.headline)
            Text("Создавайте сценарии через чат: опишите задачу и нужные поля. Фиксированные шаги выполняются без модели; сценарии со скиллом используют его инструкцию.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.features.workflows){workflow in
                HStack{VStack(alignment:.leading){Text(workflow.name).font(.callout.weight(.medium));Text(workflow.steps?.isEmpty == false ? "Фиксированных шагов: \(workflow.steps?.count ?? 0)" : "Промпт и параметры для агента").font(.caption).foregroundStyle(.secondary)};Spacer();Button("Заполнить"){store.addMessage(.init(role:"workflow_form",text:workflow.id.uuidString),to:chatID)}}
            }
        }.padding(18).agentCard()
    }
}
struct WorkflowFormCard:View{
    @EnvironmentObject var store:AppStore
    let workflowID:UUID
    let chatID:UUID
    @State private var values:[String:String]=[:]
    @State private var failure:String?
    private var workflow:LocalWorkflow?{store.features.workflows.first{$0.id==workflowID}}
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            if let workflow{
                Label(workflow.name,systemImage:"play.rectangle").font(.headline)
                ForEach(workflow.fields){field in fieldView(field)}
                if let failure{Text(failure).font(.caption).foregroundStyle(.orange)}
                Text("Параметры фиксируются при запуске. Для их изменения после начала остановите задачу и заполните новую форму.").font(.caption2).foregroundStyle(.secondary)
                Button("Запустить сценарий"){
                    do{
                        var input:[String:JSONValue]=[:]
                        for field in workflow.fields {
                            let raw=values[field.key] ?? display(field.defaultValue)
                            if field.kind == .number{if let number=Double(raw){input[field.key] = .number(number)}else if !raw.isEmpty{throw AgentError.message("Введите число: "+field.label)}}
                            else if field.kind == .toggle{input[field.key] = .bool(raw=="true")}
                            else if !raw.isEmpty{input[field.key] = .string(raw)}
                        }
                        try store.submitWorkflow(workflowID,values:input,chatID:chatID);failure=nil
                    }catch{failure=store.vault.redact(error.localizedDescription)}
                }.buttonStyle(.borderedProminent)
            }else{Text("Сценарий удалён. История чата сохранена.").foregroundStyle(.secondary)}
        }.padding(18).agentCard()
    }
    private func display(_ value:JSONValue?)->String{guard let value else{return ""};return value.string ?? value.encoded}
    @ViewBuilder private func fieldView(_ field:WorkflowField)->some View{
        let binding=Binding<String>(get:{values[field.key] ?? display(field.defaultValue)},set:{values[field.key]=$0})
        if field.kind == .choice{
            Picker(field.label,selection:binding){Text("Выберите…").tag("");ForEach(field.choices ?? [],id:\.self){Text($0).tag($0)}}
        }else if field.kind == .toggle{
            Toggle(field.label,isOn:Binding(get:{binding.wrappedValue=="true"},set:{binding.wrappedValue=String($0)}))
        }else{
            VStack(alignment:.leading,spacing:4){
                Text(field.label).font(.caption).foregroundStyle(.secondary)
                HStack{
                    TextField(field.label,text:binding).textFieldStyle(.roundedBorder)
                    if field.kind == .file || field.kind == .folder{Button("Выбрать…"){let panel=NSOpenPanel();panel.canChooseDirectories=field.kind == .folder;panel.canChooseFiles=field.kind == .file;if panel.runModal() == .OK,let url=panel.url{binding.wrappedValue=url.path}}}
                }
            }
        }
    }
}
struct AutomationsCard:View{
    @EnvironmentObject var store:AppStore
    let chatID:UUID
    @State private var name=""
    @State private var prompt=""
    @State private var folder=""
    @State private var ext=""
    @State private var trigger=LocalAutomation.Trigger.daily
    @State private var hour=9
    @State private var minute=0
    @State private var history:[AutomationRun]=[]
    @State private var failure:String?
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            Label("Локальные автоматизации",systemImage:"clock.arrow.circlepath").font(.headline)
            Text("Работают в вашей сессии macOS. Закрытое приложение может открыться в фоне. Спящий Mac не пробуждается; дневное расписание догоняется один раз сегодня. Обычные подтверждения действий сохраняются.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.features.automations){rule in
                HStack{VStack(alignment:.leading){Text(rule.name).font(.callout.weight(.medium));Text(rule.trigger == .daily ? "\(rule.hour):\(String(format:"%02d",rule.minute)) · \(rule.timeZone)" : rule.folder ?? "").font(.caption).foregroundStyle(.secondary)};Spacer();Toggle("Включена",isOn:Binding(get:{store.features.automations.first{$0.id==rule.id}?.enabled==true},set:{value in if let i=store.features.automations.firstIndex(where:{$0.id==rule.id}){store.features.automations[i].enabled=value;store.save();Task{do{try await store.syncAutomationHelper()}catch{failure=error.localizedDescription}}}})).toggleStyle(.switch).controlSize(.small)}
            }
            DisclosureGroup("Новая автоматизация"){
                VStack(alignment:.leading,spacing:10){
                    TextField("Название",text:$name);TextField("Что поручить агенту",text:$prompt,axis:.vertical)
                    Picker("Запуск",selection:$trigger){Text("Ежедневно").tag(LocalAutomation.Trigger.daily);Text("Изменения папки").tag(LocalAutomation.Trigger.folder)}
                    if trigger == .daily{HStack{Stepper("Час: \(hour)",value:$hour,in:0...23);Stepper("Минуты: \(minute)",value:$minute,in:0...59)}}
                    else{HStack{TextField("Папка",text:$folder);Button("Выбрать…"){let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;if panel.runModal() == .OK{folder=panel.url?.path ?? ""}}};TextField("Расширение без точки, необязательно",text:$ext)}
                    Button("Создать и включить"){
                        do{
                            guard store.vault.redact(prompt)==prompt else{throw AgentError.message("Не сохраняйте секреты в автоматизации")}
                            var rule=LocalAutomation(name:name,chatID:chatID,prompt:prompt,trigger:trigger,hour:hour,minute:minute)
                            if trigger == .folder{rule.folder=try FileTools(paths:store.storage.paths).resolve(folder,workingDirectory:nil).path;if !ext.isEmpty{rule.fileExtension=ext}}
                            try rule.validated();var next=store.features;next.automations.append(rule);try next.validated();store.features=next;store.save()
                            name="";prompt="";Task{do{try await store.syncAutomationHelper();await store.featureMaintenance();reload()}catch{failure=error.localizedDescription}}
                        }catch{failure=store.vault.redact(error.localizedDescription)}
                    }.disabled(name.isEmpty || prompt.isEmpty)
                }.textFieldStyle(.roundedBorder).padding(.top,8)
            }
            DisclosureGroup("История событий"){
                ForEach(Array(history.prefix(30))){run in Text(run.createdAt.formatted()+" · "+run.status+" · "+run.detail).font(.caption).textSelection(.enabled)}
                Button("Обновить"){reload()}
            }
            if let failure{Text(failure).font(.caption).foregroundStyle(.orange)}
            if let notice=store.featureNotice{Text(notice).font(.caption).foregroundStyle(.orange)}
        }.padding(18).agentCard().task{reload()}
    }
    private func reload(){do{history=try AutomationScheduler.history(paths:store.storage.paths)}catch{failure=store.vault.redact(error.localizedDescription)}}
}
