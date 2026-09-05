import SwiftUI

/// Unsaved changes stay visible until recovery succeeds. This banner has no
/// dismissal action, unlike transient errors while reading history.
struct HistoryRecoveryBanner: View {
    let pendingCount: Int
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                pendingCount == 0
                    ? "History recovery needs attention"
                    : "Unsaved history changes: \(pendingCount)",
                systemImage: "exclamationmark.triangle.fill")
                .font(Typography.bodyMedium)
                .foregroundStyle(Color.accentError)
            Text(message)
                .font(Typography.bodySmall)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry saves", action: retry)
                .accessibilityLabel("Retry unsaved history changes")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.bgHover, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24)
    }
}
