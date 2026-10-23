import Foundation
import CloudKit
import Security

public final class RemoteCloudMailbox {
    public static let containerIdentifier = "iCloud.studio.stix.agent"
    private let database: CKDatabase
    private let container: CKContainer

    #if targetEnvironment(simulator)
    public init?() { return nil }
    #else
    public init?() {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(task,
                  "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              containers.contains(Self.containerIdentifier) else { return nil }
        #endif
        container = CKContainer(identifier: Self.containerIdentifier)
        database = container.privateCloudDatabase
    }
    #endif

    public func isAvailable() async -> Bool { await availabilityIssue() == nil }

    public func availabilityIssue() async -> String? {
        let status: CKAccountStatus
        do { status = try await container.accountStatus() }
        catch { return "Проверка iCloud: \(error.localizedDescription)" }
        guard status == .available else { return "Apple Account не доступен для CloudKit (код \(status.rawValue))" }
        do {
            _ = try await database.record(for: CKRecord.ID(recordName: "stix-remote-probe-v1"))
            return nil
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch let error as CKError {
            return "CloudKit: \(error.code.rawValue) — \(error.localizedDescription)"
        } catch {
            return "CloudKit: \(error.localizedDescription)"
        }
    }

    public func sendToMac(_ envelope: RemoteEnvelope) async throws {
        try await write(envelope, direction: "to-mac")
    }

    public func sendToPhone(_ envelope: RemoteEnvelope) async throws {
        try await write(envelope, direction: "to-phone")
    }

    public func notifyPhone(_ envelope: RemoteEnvelope) async throws {
        try await write(envelope, direction: "phone-notification")
    }

    public func latestForMac(peerID: UUID) async throws -> RemoteEnvelope? {
        try await read(peerID: peerID, direction: "to-mac")
    }

    public func latestForPhone(peerID: UUID) async throws -> RemoteEnvelope? {
        try await read(peerID: peerID, direction: "to-phone")
    }

    public func installChangeSubscription(id: String) async throws {
        do {
            _ = try await database.subscription(for: id)
            return
        } catch let error as CKError where error.code == .unknownItem {
            let subscription = CKDatabaseSubscription(subscriptionID: id)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            _ = try await database.save(subscription)
        }
    }

    private func recordID(peerID: UUID, direction: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "v1-\(peerID.uuidString.lowercased())-\(direction)")
    }

    private func write(_ envelope: RemoteEnvelope, direction: String) async throws {
        let id = recordID(peerID: envelope.peerID, direction: direction)
        let payload = try JSONEncoder().encode(envelope)
        guard payload.count <= RemoteFraming.maxFrame else { throw RemoteChatError.oversized }
        for attempt in 0..<3 {
            let record = (try? await database.record(for: id)) ?? CKRecord(recordType: "EncryptedRemoteFrame", recordID: id)
            record["requestID"] = envelope.requestID.uuidString as CKRecordValue
            record["updatedAt"] = Date() as CKRecordValue
            var temporaryFile: URL?
            defer { if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) } }
            if payload.count <= 400_000 {
                record["wire"] = payload as CKRecordValue
                record["asset"] = nil
            } else {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("stix-cloud-\(UUID().uuidString)")
                try payload.write(to: file, options: .atomic)
                temporaryFile = file
                record["wire"] = nil
                record["asset"] = CKAsset(fileURL: file)
            }
            do { _ = try await database.save(record); return }
            catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 { continue }
        }
    }

    private func read(peerID: UUID, direction: String) async throws -> RemoteEnvelope? {
        let record: CKRecord
        do { record = try await database.record(for: recordID(peerID: peerID, direction: direction)) }
        catch let error as CKError where error.code == .unknownItem { return nil }
        let bytes: Data?
        if let wire = record["wire"] as? Data { bytes = wire }
        else if let asset = record["asset"] as? CKAsset, let file = asset.fileURL {
            bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        } else { bytes = nil }
        guard let bytes, bytes.count <= RemoteFraming.maxFrame else { return nil }
        return try JSONDecoder().decode(RemoteEnvelope.self, from: bytes)
    }
}
