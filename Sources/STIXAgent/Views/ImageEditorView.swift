import SwiftUI
import AppKit

/// A non-destructive editor: originals and generated versions remain chat attachments.
struct ImageEditorView: View {
    let source: Attachment
    var versions: [Attachment] = []
    let onSubmit: (String, [Attachment]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Attachment?
    @State private var prompt = ""
    @State private var strength = 0.75
    @State private var brushSize = 0.06
    @State private var erasing = false
    @State private var strokes: [ImageMaskStroke] = []
    @State private var currentPoints: [CGPoint] = []
    @State private var comparing = false
    @State private var comparison = 0.5
    @State private var error: String?
    @State private var preparing = false

    private var input: Attachment { selected ?? source }
    private var image: NSImage? { NSImage(contentsOfFile: input.path) }
    private var history: [Attachment] {
        var paths: Set<String> = []
        return ([source] + versions).filter { $0.kind == "image" && paths.insert($0.path).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Редактирование изображения").font(.title2.weight(.semibold))
                    Text("Закрасьте область изменений или измените всё изображение. Оригинал сохраняется.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 10) {
                    imageCanvas.frame(minWidth: 380, minHeight: 320, maxHeight: .infinity)
                    HStack {
                        Toggle("До / после", isOn: $comparing).toggleStyle(.switch).controlSize(.small)
                        if comparing {
                            Slider(value: $comparison, in: 0...1).help("Слева — оригинал, справа — выбранная версия")
                        } else {
                            Picker("Инструмент", selection: $erasing) {
                                Text("Кисть").tag(false)
                                Text("Ластик").tag(true)
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 165)
                            Slider(value: $brushSize, in: 0.008...0.22).frame(width: 100).help("Размер кисти")
                            Button { if !strokes.isEmpty { strokes.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                                .disabled(strokes.isEmpty).help("Отменить штрих")
                            Button("Сбросить") { strokes = []; currentPoints = [] }.disabled(strokes.isEmpty)
                        }
                    }
                }
                controls.frame(width: 255)
            }
            if history.count > 1 { versionStrip }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text(strokes.contains(where: { !$0.erasing }) ? "Розовая область — маска изменений" : "Без маски изменится всё изображение")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: submit) {
                    if preparing { ProgressView().controlSize(.small) }
                    else { Label("Создать новую версию", systemImage: "sparkles") }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(preparing || image == nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(minWidth: 880, idealWidth: 1040, minHeight: 660, idealHeight: 780)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Что изменить").font(.headline)
            TextEditor(text: $prompt).font(.body).scrollContentBackground(.hidden)
                .padding(8).frame(height: 180)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Описание изменений изображения")
            HStack { Text("Сила изменений"); Spacer(); Text(strength, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
                .font(.callout)
            Slider(value: $strength, in: 0.05...1)
            Text("Меньше — ближе к исходнику. Больше — заметнее изменения.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(input.name).font(.caption).lineLimit(2).textSelection(.enabled)
            Text("Результат появится в чате отдельным изображением. Вы сможете открыть его, сравнить и продолжить редактирование.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var imageCanvas: some View {
        GeometryReader { geometry in
            if let image {
                let size = ImageEditorGeometry.fit(image.size, inside: geometry.size)
                ZStack {
                    Color.black.opacity(0.06)
                    ZStack(alignment: .leading) {
                        Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                        if comparing, let original = NSImage(contentsOfFile: source.path) {
                            Image(nsImage: original).resizable().scaledToFit().frame(width: size.width, height: size.height)
                                .mask(alignment: .leading) { Rectangle().frame(width: size.width * comparison) }
                            Rectangle().fill(.white).frame(width: 2).offset(x: size.width * comparison - 1)
                            VStack { HStack { Text("Оригинал"); Spacer(); Text("Версия") }; Spacer() }
                                .font(.caption.weight(.medium)).foregroundStyle(.white).shadow(radius: 2).padding(10)
                        } else {
                            Canvas { context, canvasSize in
                                for stroke in visibleStrokes {
                                    let points = stroke.points.map { CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height) }
                                    guard let first = points.first else { continue }
                                    var path = Path(); path.move(to: first)
                                    for point in points.dropFirst() { path.addLine(to: point) }
                                    if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
                                    context.blendMode = stroke.erasing ? .destinationOut : .normal
                                    context.stroke(path, with: .color(.pink.opacity(0.55)), style: StrokeStyle(lineWidth: stroke.width * canvasSize.width, lineCap: .round, lineJoin: .round))
                                }
                            }.frame(width: size.width, height: size.height).compositingGroup()
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                    let point = CGPoint(x: min(1, max(0, value.location.x / size.width)), y: min(1, max(0, value.location.y / size.height)))
                                    currentPoints.append(point)
                                }.onEnded { _ in
                                    if !currentPoints.isEmpty { strokes.append(.init(points: currentPoints, width: brushSize, erasing: erasing)); currentPoints = [] }
                                })
                                .accessibilityLabel("Маска: рисуйте область изменений")
                        }
                    }.frame(width: size.width, height: size.height).clipped()
                }.frame(width: geometry.size.width, height: geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                ContentUnavailableView("Изображение недоступно", systemImage: "photo", description: Text("Исходный файл не удалось прочитать."))
            }
        }
    }

    private var visibleStrokes: [ImageMaskStroke] {
        strokes + (currentPoints.isEmpty ? [] : [.init(points: currentPoints, width: brushSize, erasing: erasing)])
    }

    private var versionStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Изображения в истории чата · \(history.count)").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(history.enumerated()), id: \.element.id) { index, attachment in
                        Button {
                            selected = attachment; strokes = []; currentPoints = []; error = nil
                        } label: {
                            VStack(spacing: 4) {
                                if let thumbnail = NSImage(contentsOfFile: attachment.path) {
                                    Image(nsImage: thumbnail).resizable().scaledToFit().frame(width: 74, height: 58)
                                } else { Image(systemName: "photo.badge.exclamationmark").frame(width: 74, height: 58) }
                                Text(index == 0 ? "Оригинал" : "Картинка \(index)").font(.caption2)
                            }.padding(5).background(input.path == attachment.path ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(input.path == attachment.path ? Color.accentColor : .clear))
                        }.buttonStyle(.plain).help(attachment.name)
                    }
                }
            }
        }
    }

    private func submit() {
        preparing = true; error = nil
        do {
            guard let image else { throw AgentError.message("Исходное изображение недоступно") }
            var maskPath: String?
            if strokes.contains(where: { !$0.erasing }) {
                let pixels = try ImageEditorGeometry.pixelSize(image)
                maskPath = try ImageMaskExporter.save(strokes: strokes, width: pixels.width, height: pixels.height).path
            }
            let command = try ImageEditorCommand.make(prompt: prompt, source: input, imageSize: image.size, strength: strength, maskPath: maskPath)
            onSubmit(command, [input])
            dismiss()
        } catch { self.error = error.localizedDescription }
        preparing = false
    }
}

struct ImageMaskStroke {
    var points: [CGPoint]
    /// Brush diameter as a fraction of image width.
    var width: Double
    var erasing: Bool
}

enum ImageEditorGeometry {
    static func fit(_ image: CGSize, inside bounds: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    static func pixelSize(_ image: NSImage) throws -> (width: Int, height: Int) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0, cg.width <= 16_384, cg.height <= 16_384,
              cg.width * cg.height <= 32_000_000 else { throw AgentError.message("Изображение слишком большое для маски (максимум 32 Мп)") }
        return (cg.width, cg.height)
    }
}

enum ImageEditorCommand {
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func make(prompt: String, source: Attachment, imageSize: CGSize, strength: Double, maskPath: String?) throws -> String {
        guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0 else { throw AgentError.message("Некорректный размер изображения") }
        // Respect ComfyUI's validated dimensions while retaining aspect ratio where possible.
        let scale = min(1, 2048 / max(imageSize.width, imageSize.height))
        let width = min(2048, max(256, Int((imageSize.width * scale / 8).rounded()) * 8))
        let height = min(2048, max(256, Int((imageSize.height * scale / 8).rounded()) * 8))
        let decimal = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), strength)
        var command = "/image --input \(quote(source.path)) --size \(width)x\(height) --denoise \(decimal)"
        if let maskPath { command += " --mask \(quote(maskPath))" }
        command += " -- \(quote(prompt.trimmingCharacters(in: .whitespacesAndNewlines)))"
        _ = try ImageRequest.parse(command)
        return command
    }
}

enum ImageMaskExporter {
    /// RGB masks match ComfyClient's ImageToMask red channel: white edits, black preserves.
    static func save(strokes: [ImageMaskStroke], width: Int, height: Int, directory: URL = AppStoragePaths().attachments.appendingPathComponent("ImageMasks", isDirectory: true)) throws -> URL {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 32_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw AgentError.message("Не удалось создать маску изображения")
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round); context.setLineJoin(.round)
        for stroke in strokes {
            guard stroke.width.isFinite, stroke.width > 0, stroke.width <= 1,
                  stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
                  let first = stroke.points.first else { throw AgentError.message("Некорректный штрих маски") }
            context.setStrokeColor(CGColor(gray: stroke.erasing ? 0 : 1, alpha: 1))
            context.setLineWidth(stroke.width * Double(width))
            context.beginPath(); context.move(to: CGPoint(x: first.x * CGFloat(width), y: first.y * CGFloat(height)))
            for point in stroke.points.dropFirst() { context.addLine(to: CGPoint(x: point.x * CGFloat(width), y: point.y * CGFloat(height))) }
            if stroke.points.count == 1 { context.addLine(to: CGPoint(x: first.x * CGFloat(width) + 0.01, y: first.y * CGFloat(height))) }
            context.strokePath()
        }
        guard let cgImage = context.makeImage(), let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw AgentError.message("Не удалось сохранить PNG-маску")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("mask-\(UUID().uuidString).png")
        try png.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
