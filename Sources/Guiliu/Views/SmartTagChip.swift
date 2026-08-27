import GuiliuCore
import SwiftUI

struct SmartTagChip: View {
    let tag: SmartTag
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbolName)
                Text(tag.displayName)
                    .lineLimit(1)
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(isHovering ? 0.15 : 0.09), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tint.opacity(isHovering ? 0.22 : 0.11), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("搜索标签“\(tag.displayName)”")
        .accessibilityLabel("按标签 \(tag.displayName) 搜索")
    }

    private var symbolName: String {
        switch tag.kind {
        case .importance: "star.fill"
        case .project: "folder.badge.gearshape"
        case .organization: "building.2.fill"
        case .documentType: "doc.text.fill"
        case .topic: "number"
        case .source: "square.and.arrow.down"
        }
    }

    private var tint: Color {
        switch tag.kind {
        case .importance: .orange
        case .project: .indigo
        case .organization: .blue
        case .documentType: .teal
        case .topic: .purple
        case .source: .secondary
        }
    }
}
