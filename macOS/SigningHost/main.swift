import Foundation
import CloudKit
import Security

// This target provisions CloudKit for the Swift Package app and can diagnose
// account/container access. The helper binary is never shipped.
Task {
    if let task = SecTaskCreateFromSelf(nil),
       let containers = SecTaskCopyValueForEntitlement(task,
           "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String] {
        print("CloudKit entitlement present: \(containers.contains("iCloud.studio.stix.agent"))")
    } else {
        print("CloudKit entitlement unavailable to SecTask")
    }
    let container = CKContainer(identifier: "iCloud.studio.stix.agent")
    do {
        let status = try await container.accountStatus()
        print("CloudKit account status: \(status.rawValue)")
        do {
            _ = try await container.privateCloudDatabase.record(for: CKRecord.ID(recordName: "stix-remote-probe-v1"))
            print("CloudKit container: available")
        } catch let error as CKError where error.code == .unknownItem {
            print("CloudKit container: available (probe record absent)")
        } catch let error as CKError {
            print("CloudKit container error: \(error.code.rawValue) \(error.localizedDescription)")
        }
    } catch {
        print("CloudKit account error: \(error.localizedDescription)")
    }
    exit(0)
}
RunLoop.main.run()
