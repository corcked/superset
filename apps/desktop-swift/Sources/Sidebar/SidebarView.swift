import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: SidebarViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.projects.isEmpty {
                emptyState
            } else {
                projectList
            }

            Divider()
            footerBar
        }
        .frame(minWidth: 180)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Add a project to get started")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Add Project") {
                viewModel.addProject()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.projects) { pww in
                    ProjectRowView(
                        project: pww.project,
                        workspaces: pww.workspaces,
                        activeWorkspaceId: viewModel.activeWorkspaceId,
                        onSelectWorkspace: { id in viewModel.selectWorkspace(id: id) },
                        onCreateWorkspace: { projectId, branch in
                            viewModel.createWorkspace(projectId: projectId, branchName: branch)
                        },
                        onDeleteWorkspace: { id in viewModel.deleteWorkspace(id: id) },
                        gitStatusForWorkspace: { workspace in
                            viewModel.gitStatus(for: workspace)
                        }
                    )
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var footerBar: some View {
        HStack {
            Button(action: { viewModel.addProject() }) {
                Label("Add Project", systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Spacer()
        }
    }
}
