import SwiftUI

/// Navigation and input use system glass; reading surfaces stay quiet and opaque enough for text.
extension View {
    func agentGlass(cornerRadius: CGFloat, interactive: Bool = false, enabled: Bool = true) -> some View {
        modifier(AgentGlassSurface(cornerRadius: cornerRadius, interactive: interactive, enabled: enabled))
    }

    func agentCard(cornerRadius: CGFloat = 20) -> some View {
        background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.065), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

private struct AgentGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    let interactive: Bool
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if !enabled {
            content
        } else if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay { shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false) }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay { shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false) }
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        }
    }
}
