import SwiftUI

struct SlashSuggestionsView: View {
    static func height(for count: Int) -> CGFloat { min(278, CGFloat(count * 52)) + 48 }
    let items: [SlashCommandItem]
    @Binding var selection: Int
    let choose: (SlashCommandItem) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Команды и плагины").font(.caption.weight(.medium))
                Spacer()
                Text("↑ ↓  ·  ↵ выбрать  ·  Esc").font(.caption2)
            }.foregroundStyle(.secondary).frame(height: 16).padding(.horizontal, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button { choose(item) } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: item.icon).frame(width: 24).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack { Text(item.title).font(.system(size: 12, weight: .medium)); Spacer(); Text(item.command).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
                                        Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }.padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
                                    .background(selection == index ? Color.primary.opacity(0.065) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
                            }.buttonStyle(.plain).disabled(!item.enabled).id(item.id)
                                .accessibilityLabel(item.title + ", " + item.command)
                        }
                    }
                }.frame(height: min(278, CGFloat(items.count * 52)))
                    .onChange(of: selection) { _, value in if items.indices.contains(value) { proxy.scrollTo(items[value].id, anchor: .center) } }
            }
        }.padding(12).agentGlass(cornerRadius: 20)
    }
}
