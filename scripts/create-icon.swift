import AppKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Double(pixels)*0.045, dy: Double(pixels)*0.045), xRadius: Double(pixels)*0.23, yRadius: Double(pixels)*0.23).fill()
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x: Double(pixels)/2, y: Double(pixels)/2)
        NSColor.white.setStroke()
        for _ in 0..<3 {
            let path = NSBezierPath(); path.lineWidth = Double(pixels)*0.075; path.lineCapStyle = .round
            path.move(to: NSPoint(x: 0, y: -Double(pixels)*0.23)); path.line(to: NSPoint(x: 0, y: Double(pixels)*0.23)); path.stroke()
            context.rotate(by: .pi/3)
        }
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = rep.representation(using: .png, properties: [:])!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: directory.appendingPathComponent(name))
    }
}
