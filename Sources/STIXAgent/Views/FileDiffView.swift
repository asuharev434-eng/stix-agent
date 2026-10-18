import SwiftUI

struct FileDiffSnapshot: Sendable {
    let path: String
    let destination: String?
    let kind: String
    let before: String?
    let after: String?
}

/// Contextual line diff with bounded work, even for generated or minified files.
struct FileTextDiff: Sendable {
    enum Kind: Sendable { case context, removed, added, omitted }
    struct Line: Identifiable, Sendable {
        let id: Int
        let kind: Kind
        let oldNumber: Int?
        let newNumber: Int?
        let text: String
    }
    let lines: [Line]
    let additions: Int
    let removals: Int
    let truncated: Bool

    init(before: String?, after: String?, context: Int = 3, maximumRows: Int = 600) {
        let oldAll = before.map { $0.components(separatedBy: "\n") } ?? []
        let newAll = after.map { $0.components(separatedBy: "\n") } ?? []
        let old = Array(oldAll.prefix(10_000)), new = Array(newAll.prefix(10_000))
        var edits: [(Kind, String)] = []
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix, old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        edits += old.prefix(prefix).map { (.context, $0) }
        let a = Array(old[prefix..<(old.count - suffix)])
        let b = Array(new[prefix..<(new.count - suffix)])
        if (a.count + 1) * (b.count + 1) <= 1_000_000 {
            let width = b.count + 1
            var lengths = [Int](repeating: 0, count: (a.count + 1) * width)
            if !a.isEmpty && !b.isEmpty {
                for i in (0..<a.count).reversed() {
                    for j in (0..<b.count).reversed() {
                        lengths[i * width + j] = a[i] == b[j] ? 1 + lengths[(i + 1) * width + j + 1]
                            : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, a[i] == b[j] { edits.append((.context, a[i])); i += 1; j += 1 }
                else if i < a.count, j == b.count || lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                    edits.append((.removed, a[i])); i += 1
                } else { edits.append((.added, b[j])); j += 1 }
            }
        } else {
            edits += a.map { (.removed, $0) }
            edits += b.map { (.added, $0) }
        }
        edits += old.suffix(suffix).map { (.context, $0) }
        additions = edits.filter { $0.0 == .added }.count
        removals = edits.filter { $0.0 == .removed }.count
        var visible = Set<Int>()
        let radius = min(max(context, 0), 20)
        for index in edits.indices where edits[index].0 != .context {
            for nearby in max(0, index - radius)...min(edits.count - 1, index + radius) { visible.insert(nearby) }
        }
        if visible.isEmpty { visible.formUnion(edits.indices.prefix(radius * 2 + 1)) }
        var rows: [Line] = []
        var oldNumber = 1, newNumber = 1, skipped = 0
        func appendSkipped() {
            if skipped > 0 { rows.append(Line(id: rows.count, kind: .omitted, oldNumber: nil, newNumber: nil, text: "… \(skipped) строк без изменений")); skipped = 0 }
        }
        for (index, edit) in edits.enumerated() {
            if visible.contains(index) {
                appendSkipped()
                rows.append(Line(id: rows.count, kind: edit.0, oldNumber: edit.0 == .added ? nil : oldNumber, newNumber: edit.0 == .removed ? nil : newNumber, text: edit.1))
            } else { skipped += 1 }
            if edit.0 != .added { oldNumber += 1 }
            if edit.0 != .removed { newNumber += 1 }
        }
        appendSkipped()
        let limit = max(1, maximumRows)
        truncated = oldAll.count > old.count || newAll.count > new.count || rows.count > limit
        lines = Array(rows.prefix(limit))
    }
}

struct FileDiffView: View {
    let record: UndoRecord
    let paths: AppStoragePaths
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: FileDiffSnapshot?
    @State private var diff: FileTextDiff?
    @State private var error: String?
    @State private var mode = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Изменения файла", systemImage: "doc.text.magnifyingglass").font(.headline)
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(record.source).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            if let destination = record.destination, record.kind == "move" {
                Label(destination, systemImage: "arrow.right").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            if let snapshot, let diff {
                HStack {
                    Picker("Просмотр", selection: $mode) {
                        Text("Изменения").tag(0); Text("До").tag(1); Text("После").tag(2)
                    }.pickerStyle(.segmented).frame(width: 280)
                    Spacer()
                    if diff.truncated { Text("Фрагмент").foregroundStyle(.secondary) }
                    Text("+\(diff.additions)").foregroundStyle(.green)
                    Text("−\(diff.removals)").foregroundStyle(.red)
                }.font(.system(size: 12, design: .monospaced))
                if mode == 0 {
                    if snapshot.before == snapshot.after { Text("Содержимое не изменилось").foregroundStyle(.secondary) }
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(diff.lines) { line in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(line.oldNumber.map(String.init) ?? "").frame(width: 42, alignment: .trailing).foregroundStyle(.secondary)
                                    Text(line.newNumber.map(String.init) ?? "").frame(width: 42, alignment: .trailing).foregroundStyle(.secondary)
                                    Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").frame(width: 10)
                                    Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.system(size: 12, design: .monospaced)).padding(.vertical, 2).padding(.horizontal, 8)
                                    .background(line.kind == .added ? Color.green.opacity(0.12) : line.kind == .removed ? Color.red.opacity(0.12) : .clear)
                            }
                        }.frame(minWidth: 660, alignment: .leading)
                    }
                    if diff.truncated { Text("Показан фрагмент большого изменения. Полный текст доступен во вкладках «До» и «После».").font(.caption).foregroundStyle(.secondary) }
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text((mode == 1 ? snapshot.before : snapshot.after) ?? "Файл отсутствует")
                            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Text("Бинарные файлы и каталоги можно просмотреть в Finder. Предпросмотр не изменяет файлы.").font(.caption).foregroundStyle(.secondary)
            } else { ProgressView("Чтение изменения…") }
            Spacer(minLength: 0)
        }.padding(20).frame(minWidth: 720, idealWidth: 900, minHeight: 460, idealHeight: 620)
            .task(id: record.id) {
                do {
                    let receipt = record, storage = paths
                    let loaded = try await Task.detached(priority: .userInitiated) {
                        let snapshot = try FileTools(paths: storage).diffSnapshot(receipt)
                        return (snapshot, FileTextDiff(before: snapshot.before, after: snapshot.after))
                    }.value
                    snapshot = loaded.0; diff = loaded.1
                } catch { self.error = error.localizedDescription }
            }
    }
}
