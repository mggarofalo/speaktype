import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        VStack(spacing: 0) {
            // Space for traffic lights
            Spacer()
                .frame(height: SidebarConstants.topInset)

            // Logo Header
            SidebarHeader()
                .padding(.horizontal, SidebarConstants.horizontalPadding)
                .padding(.bottom, SidebarConstants.headerBottomPadding)

            // Navigation Items
            VStack(spacing: SidebarConstants.itemSpacing) {
                ForEach(SidebarItem.allCases) { item in
                    SidebarButton(
                        item: item,
                        isSelected: selection == item,
                        action: { selection = item }
                    )
                }
            }
            .padding(.horizontal, SidebarConstants.itemHorizontalPadding)

            Spacer()

            // Build version indicator — debug only, never shown in production
            #if DEBUG
                Text(buildVersionString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.textMuted.opacity(0.35))
                    .padding(.bottom, 14)
            #else
                Spacer().frame(height: 14)
            #endif
        }
        .frame(width: SidebarConstants.width)
    }

    private var buildVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(version) (\(buildTimestamp))"
    }
}

// MARK: - Constants

private enum SidebarConstants {
    static let width: CGFloat = 260
    static let topInset: CGFloat = 52
    static let horizontalPadding: CGFloat = 20
    static let itemHorizontalPadding: CGFloat = 14
    static let headerBottomPadding: CGFloat = 28
    static let itemSpacing: CGFloat = 2
    static let bottomPadding: CGFloat = 20
    static let iconSize: CGFloat = 17
    static let itemVerticalPadding: CGFloat = 11
    static let itemCornerRadius: CGFloat = 8
}

// MARK: - Components

private struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)

            Text("SpeakType")
                .font(Typography.sidebarLogo)
                .foregroundStyle(Color.textPrimary)

            Spacer()
        }
    }
}

struct SidebarButton: View {
    let item: SidebarItem
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: SidebarConstants.iconSize))
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textMuted)
                    .frame(width: 20)

                Text(item.rawValue)
                    .font(isSelected ? Typography.sidebarItemActive : Typography.sidebarItem)
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, SidebarConstants.itemVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: SidebarConstants.itemCornerRadius)
                    .fill(isSelected ? Color.bgSelected : (isHovered ? Color.bgHover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Sidebar Items

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case transcribeAudio = "Transcribe Audio"
    case history = "History"
    case statistics = "Statistics"
    case aiModels = "AI Models"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .transcribeAudio: return "waveform"
        case .history: return "doc.text"
        case .statistics: return "chart.bar"
        case .aiModels: return "cpu"
        case .settings: return "gearshape"
        }
    }
}
