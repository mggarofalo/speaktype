import SwiftUI

/// History actions must remain visible independently of the window's tint.
struct HistoryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(HistoryActionSurface(isPressed: configuration.isPressed))
    }
}

/// Disabled controls keep readable labels but lose hover feedback.
private struct HistoryActionSurface: ViewModifier {
    var isPressed = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .font(Typography.labelMedium)
            .foregroundStyle(isEnabled ? Color.textPrimary : Color.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                isEnabled && (isHovered || isPressed)
                    ? Color.btnSecondaryHover : Color.btnSecondaryBg
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.border, lineWidth: 1)
            }
            .onHover { isHovered = $0 }
    }
}
