import AppKit
import ApplicationServices
import CoreGraphics

/// Read-only permission status; never prompts, captures a screen, or inspects document contents.
enum NativeCapabilities {
    static func status() -> [String: JSONValue] {
        var report: [String: JSONValue] = [
            "accessibility": .bool(AXIsProcessTrusted()),
            "screen_recording": .bool(CGPreflightScreenCaptureAccess()),
            "memory_gb": .number(Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
        ]
        for (name, bundle) in [("safari", "com.apple.Safari"), ("chrome", "com.google.Chrome"), ("textedit", "com.apple.TextEdit")] {
            let data = Data(bundle.utf8)
            let descriptor = NSAppleEventDescriptor(descriptorType: typeApplicationBundleID, data: data)
            let permission = descriptor.map { AEDeterminePermissionToAutomateTarget($0.aeDesc, typeWildCard, typeWildCard, false) } ?? OSStatus(-1)
            report[name] = .object(["running": .bool(!NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty), "automation_status": .number(Double(permission))])
        }
        return report
    }
}
