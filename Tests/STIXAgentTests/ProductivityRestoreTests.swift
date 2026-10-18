import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import STIXAgent

final class ProductivityRestoreTests:XCTestCase {
    @MainActor func testPortableFullRestoreAndSelectedChatKeepOriginalsAndAttachments() async throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:base)}
        let paths=AppStoragePaths(root:base.appendingPathComponent("Original"))
        let store=AppStore(storage:.init(paths:paths));store.features.automaticBackups=false
        let id=try XCTUnwrap(store.selectedID),file=paths.chatAttachments(id).appendingPathComponent("result.txt")
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("retained artifact".utf8).write(to:file)
        let message=ChatMessage(role:"assistant",text:"Keep exactly",attachments:[.init(path:file.path,kind:"file")])
        store.addMessage(message,to:id);store.draft="draft retained";store.save()
        let backup=try store.storage.createBackup(in:base.appendingPathComponent("Copies"),automatic:false)
        try await store.importChat(from:backup.url,id:id)
        XCTAssertEqual(store.chats.count,2)
        XCTAssertEqual(store.chats.first{$0.id==id}?.messages.last?.id,message.id)
        let imported=try XCTUnwrap(store.chats.first{$0.id != id})
        let importedMessage=try XCTUnwrap(imported.messages.first{$0.text=="Keep exactly"})
        XCTAssertNotEqual(importedMessage.id,message.id)
        XCTAssertEqual(try String(contentsOfFile:importedMessage.attachments[0].path,encoding:.utf8),"retained artifact")
        let destination=AppStoragePaths(root:base.appendingPathComponent("Restored"))
        _ = try LocalBackups.restore(backup.url,paths:destination)
        let restored=try XCTUnwrap(StateStorage(paths:destination).load())
        XCTAssertEqual(restored.chats.count,1)
        let restoredMessage=try XCTUnwrap(restored.chats[0].messages.first{$0.id==message.id})
        XCTAssertTrue(restoredMessage.attachments[0].path.hasPrefix(destination.root.path+"/"))
        XCTAssertEqual(try String(contentsOfFile:restoredMessage.attachments[0].path,encoding:.utf8),"retained artifact")
        XCTAssertEqual(restored.chats[0].savedDraft,"draft retained")
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"retained artifact")
    }
    @MainActor func testBackupRejectsUnlistedFileAndSymlink() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:base)}
        let store=AppStore(storage:.init(paths:.init(root:base.appendingPathComponent("Data"))))
        store.save()
        let backup=try store.storage.createBackup(in:base.appendingPathComponent("Copies"),automatic:false)
        let extra=backup.url.appendingPathComponent("Data/unlisted.txt")
        try Data().write(to:extra);XCTAssertThrowsError(try LocalBackups.verify(backup.url))
        try FileManager.default.removeItem(at:extra)
        try FileManager.default.createSymbolicLink(at:extra,withDestinationURL:base)
        XCTAssertThrowsError(try LocalBackups.verify(backup.url))
    }
    @MainActor func testImageBatchProducesResizedCopyAndUndoKeepsOriginal() async throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:base)}
        let source=base.appendingPathComponent("Input"),output=base.appendingPathComponent("Output")
        for folder in [source,output]{try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)}
        let original=source.appendingPathComponent("photo.png")
        let context=try XCTUnwrap(CGContext(data:nil,width:240,height:120,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let writer=try XCTUnwrap(CGImageDestinationCreateWithURL(original as CFURL,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(writer,try XCTUnwrap(context.makeImage()),nil);XCTAssertTrue(CGImageDestinationFinalize(writer))
        let originalData=try Data(contentsOf:original)
        let store=AppStore(storage:.init(paths:.init(root:base.appendingPathComponent("Data"))))
        let id=try XCTUnwrap(store.selectedID)
        _ = try await store.prepareImages(.object(["source":.string(source.path),"destination":.string(output.path),"width":.number(100),"format":.string("jpeg"),"quality":.number(0.85)]),chatID:id)
        let result=output.appendingPathComponent("photo.jpeg")
        let reader=try XCTUnwrap(CGImageSourceCreateWithURL(result as CFURL,nil)),image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader,0,nil))
        XCTAssertEqual(image.width,100);XCTAssertEqual(image.height,50)
        XCTAssertEqual(try Data(contentsOf:original),originalData)
        let undo=try XCTUnwrap(store.undos.values.first)
        try FileTools(paths:store.storage.paths).undo(undo)
        XCTAssertFalse(FileManager.default.fileExists(atPath:result.path));XCTAssertEqual(try Data(contentsOf:original),originalData)
    }
}

final class ProductivityRuntimeTests:XCTestCase {
    @MainActor func testAutomationInboxPersistsOnceAndEconomyDefersExecution() async throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:base)}
        let paths=AppStoragePaths(root:base.appendingPathComponent("Data")),store=AppStore(storage:.init(paths:paths))
        let id=try XCTUnwrap(store.selectedID)
        var rule=LocalAutomation(name:"Synthetic",chatID:id,prompt:"Read synthetic fixture",trigger:.daily,hour:0,minute:0)
        rule.createdAt=Date().addingTimeInterval(-86400)
        store.features.automations=[rule];store.features.resourceMode = .economy;store.features.automaticBackups=false;store.save()
        await store.featureMaintenance()
        XCTAssertEqual(store.jobs.count,1);XCTAssertEqual(store.jobs[0].status,"queued");XCTAssertFalse(store.busy)
        XCTAssertEqual(store.jobs[0].automationRuleID,rule.id)
        await store.featureMaintenance();XCTAssertEqual(store.jobs.count,1)
        let restored=try XCTUnwrap(StateStorage(paths:paths).load())
        XCTAssertEqual(restored.jobs?.first?.automationEventID,store.jobs[0].automationEventID)
        XCTAssertTrue(try AutomationScheduler.pending(paths:paths).isEmpty)
    }
    @MainActor func testInterruptedFixedStepCannotReplayUnknownSideEffect() async throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:base)}
        let store=AppStore(storage:.init(paths:.init(root:base)))
        let workflow=LocalWorkflow(name:"Guard",prompt:"",steps:[.init(tool:"read_file",arguments:.object(["path":.string("/never-read")]))])
        let job=AgentJob(chatID:try XCTUnwrap(store.selectedID),prompt:"Guard",workflowDefinition:workflow,workflowValues:[:],workflowStartedStep:0)
        do{try await store.runWorkflowJob(job,workflow:workflow);XCTFail("Unknown interrupted step must require review")}
        catch{XCTAssertTrue(error.localizedDescription.contains("неизвестен"))}
    }
    func testPDFChunksKeepRealPageNumbers() {
        let chunks=LocalDocumentIndex.chunks("Document header\nСтраница 1:\nAlpha\nСтраница 2:\nBeta",pdf:true)
        XCTAssertEqual(chunks.first{$0.2.contains("Alpha")}?.0,1)
        XCTAssertEqual(chunks.first{$0.2.contains("Beta")}?.0,2)
    }
}
