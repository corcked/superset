import SwiftUI

struct ProjectRowView: View {
    let project: Project
    let workspaces: [Workspace]
    let activeWorkspaceId: String?
    let onSelectWorkspace: (String) -> Void
    let onCreateWorkspace: (String, String) -> Void
    let onDeleteWorkspace: (String) -> Void
    let gitStatusForWorkspace: (Workspace) -> GitStatusInfo?

    @State private var isExpanded = true
    @State private var showNewBranchSheet = false
    @State private var newBranchName = ""

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(workspaces) { workspace in
                WorkspaceRowView(
                    workspace: workspace,
                    isActive: workspace.id == activeWorkspaceId,
                    gitStatus: gitStatusForWorkspace(workspace),
                    onSelect: { onSelectWorkspace(workspace.id) },
                    onDelete: workspace.isWorktreeType
                        ? { onDeleteWorkspace(workspace.id) }
                        : nil
                )
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: project.color) ?? .purple)
                    .frame(width: 8, height: 8)
                Text(project.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(workspaces.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button(action: { showNewBranchSheet = true }) {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New workspace")
            }
            .padding(.vertical, 2)
        }
        .padding(.horizontal, 8)
        .sheet(isPresented: $showNewBranchSheet) {
            newBranchSheet
        }
    }

    private var newBranchSheet: some View {
        VStack(spacing: 16) {
            Text("New Workspace")
                .font(.headline)
            TextField("Branch name", text: $newBranchName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
            HStack {
                Button("Cancel") { showNewBranchSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let branch = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !branch.isEmpty else { return }
                    onCreateWorkspace(project.id, branch)
                    newBranchName = ""
                    showNewBranchSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

extension Color {
    init?(hex: String) {
        var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexStr.hasPrefix("#") { hexStr.removeFirst() }
        guard hexStr.count == 6, let rgb = UInt64(hexStr, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
