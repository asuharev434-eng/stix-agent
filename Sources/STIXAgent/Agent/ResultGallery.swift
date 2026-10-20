import Foundation

struct GalleryItem: Identifiable {
    var id: UUID { attachment.id }
    var attachment: Attachment
    var chatID: UUID
    var messageID: UUID
    var title: String
    var prompt: String
    var createdAt: Date
    var recipe: ImageRecipe?
}
extension AppStore {
    func gallery(_ query: String = "") -> [GalleryItem] {
        var result:[GalleryItem]=[],seen=Set<UUID>()
        for chat in chats {
            for (offset,message) in chat.messages.enumerated() where message.role != "user" {
                let prompt=chat.messages.prefix(offset+1).last(where:{$0.role=="user"})?.text ?? message.detail ?? message.text
                for attachment in message.attachments where attachment.kind != "folder" && seen.insert(attachment.id).inserted {
                    let recipe=features.imageRecipes.last(where:{$0.attachmentPaths.contains(attachment.path)})
                    let item=GalleryItem(attachment:attachment,chatID:chat.id,messageID:message.id,title:chat.title,prompt:prompt,createdAt:message.createdAt,recipe:recipe)
                    if query.isEmpty || attachment.name.localizedStandardContains(query) || prompt.localizedStandardContains(query) || chat.title.localizedStandardContains(query) {result.append(item)}
                }
            }
        }
        return result.sorted{$0.createdAt>$1.createdAt}
    }
    func queueImageRecipe(_ id:UUID,variant:Bool,chatID:UUID){
        guard canPersist,features.imageRecipes.contains(where:{$0.id==id}) else{error="Параметры этой генерации не сохранены";return}
        let message=ChatMessage(role:"user",text:variant ? "Создать вариант изображения с новым seed" : "Повторить изображение с сохранёнными параметрами")
        addMessage(message,to:chatID)
        jobs.append(.init(chatID:chatID,prompt:message.text,sourceMessageID:message.id,imageRecipeID:id,imageRecipeVariant:variant));save();startNextJob()
    }
    func replayImageRecipe(_ id:UUID,variant:Bool,chatID:UUID) async throws {
        guard let recipe=features.imageRecipes.first(where:{$0.id==id}) else{throw AgentError.message("Рецепт изображения не найден")}
        var request=recipe.request;if variant{request.seed=UInt64.random(in:0...UInt64(Int32.max))};_ = try request.validated()
        let card=ChatMessage(role:"tool",text:"Повтор изображения",toolName:"generate_image",detail:"Модель: \(recipe.model)\nSeed: \(request.seed)\nПромпт: \(request.prompt)",status:"running")
        addMessage(card,to:chatID)
        if let job=jobs.firstIndex(where:{$0.id==activeJobID}){jobs[job].inputRecorded=true;jobs[job].imageSubmissionStarted=true};save();guard canPersist else{throw AgentError.message("Не удалось сохранить начало генерации")}
        let store=self
        do {
        let (imageRef,imageEngine)=try inferenceRegistry.image(for:recipe.model)
        if imageRef.provider == .comfyUI,
           !(try await LocalServices.ensureComfyServer(endpoint:preferences.comfyEndpoint,paths:storage.paths)) {
            throw AgentError.message("Выбранный локальный API ComfyUI недоступен")
        }
        let urls=try await imageEngine.generate(request:request,model:recipe.model.hasPrefix("workflow:") ? "" : imageRef.id,outputDirectory:storage.paths.chatAttachments(chatID),workflow:recipe.workflow,onStepProgress:{value,total in await store.updateImageStep(value,total:total)},onProgress:{phase in await store.updateActivity(phase)})
        let paths=storage.paths
        for url in urls{let check=try await fileWork{try ResultVerifier.image(url.path,paths:paths)};recordVerification(check);guard check.passed else{throw AgentError.message(check.detail)}}
        editMessage(card.id,chatID:chatID){$0.text="Изображение готово";$0.status="done";$0.attachments=urls.map{.init(path:$0.path,kind:"image")}}
        features.imageRecipes.append(.init(chatID:chatID,attachmentPaths:urls.map(\.path),request:request,model:recipe.model,workflow:recipe.workflow));save()
        if !request.resizeOnly {try? await imageEngine.releaseIfIdle()}
        }catch{
            editMessage(card.id,chatID:chatID){$0.status="error";$0.text="Повтор изображения прерван";$0.detail=vault.redact(error.localizedDescription)}
            throw error
        }
    }
}
