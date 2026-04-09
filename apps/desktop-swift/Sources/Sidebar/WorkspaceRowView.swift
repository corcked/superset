import SwiftUI

struct WorkspaceRowView: View {
    let workspace: Workspace
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: workspace.isBranchType ? "folder.fill" : "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(isActive ? .white : .secondary)
                    .frame(width: 16)
                Text(workspace.name)
                    .font(.callout)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(isActive ? .white : .primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Workspace", systemImage: "trash")
                }
            }
        }
        .padding(.leading, 8)
    }
}
